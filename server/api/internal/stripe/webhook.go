// Package stripe handles Stripe webhook events. We care about three:
//
//   - checkout.session.completed  → first-time subscription, create account
//   - customer.subscription.updated → tier change or renewal (update active_until)
//   - customer.subscription.deleted → cancel/past-due (deactivate)
//
// The webhook signature is verified against STRIPE_WEBHOOK_SECRET. Anything
// else is rejected with 400. Events we don't care about return 200 so Stripe
// stops retrying.
//
// No-account model: checkout.session.completed generates a random account
// number (package account), stores only its HMAC, and writes the plaintext
// into the Stripe customer's metadata for recovery. See
// docs/BILLING_INTEGRATION.md.
package stripe

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"

	stripego "github.com/stripe/stripe-go/v79"
	"github.com/stripe/stripe-go/v79/customer"
	"github.com/stripe/stripe-go/v79/webhook"

	"github.com/cloakvpn/api/internal/account"
	"github.com/cloakvpn/api/internal/store"
)

type Config struct {
	WebhookSecret string

	// Stripe price IDs for each (tier, interval) combo. Populated from env.
	PriceBasicMonth string
	PriceBasicYear  string
	PriceProMonth   string
	PriceProYear    string

	BasicDeviceLimit int
	ProDeviceLimit   int

	// AccountNumberSecret keys the HMAC used to hash account numbers.
	AccountNumberSecret string
}

type Handler struct {
	cfg Config
	db  *store.DB
}

func NewHandler(cfg Config, db *store.DB) *Handler {
	return &Handler{cfg: cfg, db: db}
}

// Webhook is the HTTP handler wired at /v1/webhook/stripe.
func (h *Handler) Webhook(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20)) // 1 MiB hard cap
	if err != nil {
		http.Error(w, "read body", http.StatusBadRequest)
		return
	}
	sig := r.Header.Get("Stripe-Signature")
	evt, err := webhook.ConstructEvent(body, sig, h.cfg.WebhookSecret)
	if err != nil {
		log.Printf("stripe webhook: signature verify failed: %v", err)
		http.Error(w, "bad signature", http.StatusBadRequest)
		return
	}

	switch evt.Type {
	case "checkout.session.completed":
		if err := h.handleCheckoutCompleted(evt); err != nil {
			log.Printf("checkout.session.completed: %v", err)
			http.Error(w, "server", http.StatusInternalServerError)
			return
		}
	case "customer.subscription.updated":
		if err := h.handleSubscriptionUpdated(evt); err != nil {
			log.Printf("customer.subscription.updated: %v", err)
			http.Error(w, "server", http.StatusInternalServerError)
			return
		}
	case "customer.subscription.deleted":
		if err := h.handleSubscriptionDeleted(evt); err != nil {
			log.Printf("customer.subscription.deleted: %v", err)
			http.Error(w, "server", http.StatusInternalServerError)
			return
		}
	default:
		// Ignored but acknowledged.
	}
	w.WriteHeader(http.StatusOK)
}

func (h *Handler) handleCheckoutCompleted(evt stripego.Event) error {
	var sess stripego.CheckoutSession
	if err := json.Unmarshal(evt.Data.Raw, &sess); err != nil {
		return err
	}
	if sess.Customer == nil {
		log.Printf("checkout.session.completed %s: no customer handle; ignoring", sess.ID)
		return nil
	}
	customerID := sess.Customer.ID

	// Idempotency: Stripe retries webhooks. If this customer already has an
	// account, the checkout was already processed — do nothing (and never
	// mint a second account number for the same customer).
	if _, err := h.db.AccountByStripeCustomer(customerID); err == nil {
		return nil
	} else if !errors.Is(err, store.ErrNotFound) {
		return err
	}

	// Derive tier + limit from the purchased price.
	var priceID string
	if sess.LineItems != nil && len(sess.LineItems.Data) > 0 && sess.LineItems.Data[0].Price != nil {
		priceID = sess.LineItems.Data[0].Price.ID
	} else if sess.Subscription != nil && sess.Subscription.Items != nil &&
		len(sess.Subscription.Items.Data) > 0 && sess.Subscription.Items.Data[0].Price != nil {
		priceID = sess.Subscription.Items.Data[0].Price.ID
	}
	tier, limit := h.tierFor(priceID)
	if tier == store.TierNone {
		log.Printf("checkout completed for unknown price %q; ignoring", priceID)
		return nil
	}

	// Generate the account number — the customer's only credential.
	number, err := account.Generate()
	if err != nil {
		return err
	}
	hash := account.Hash(number, h.cfg.AccountNumberSecret)
	until := time.Now().Add(35 * 24 * time.Hour) // refreshed by subscription.updated

	// Write the plaintext number into the Stripe customer's metadata FIRST.
	// That is the long-term recovery copy; we never store the plaintext
	// ourselves. Doing it before the DB insert keeps a retried webhook
	// idempotent: a failure here means no account row exists yet, so the
	// retry simply regenerates and overwrites cleanly.
	mdParams := &stripego.CustomerParams{}
	mdParams.AddMetadata(account.MetadataKey, number)
	if _, err := customer.Update(customerID, mdParams); err != nil {
		return fmt.Errorf("write account number to stripe customer %s: %w", customerID, err)
	}

	if _, err := h.db.CreateAccount(hash, customerID, sess.ID, tier, limit, until); err != nil {
		return fmt.Errorf("create account: %w", err)
	}
	log.Printf("checkout.session.completed: account created (tier=%s) for customer %s", tier, customerID)
	return nil
}

func (h *Handler) handleSubscriptionUpdated(evt stripego.Event) error {
	var sub stripego.Subscription
	if err := json.Unmarshal(evt.Data.Raw, &sub); err != nil {
		return err
	}
	if sub.Customer == nil || sub.Items == nil || len(sub.Items.Data) == 0 {
		return nil
	}
	priceID := sub.Items.Data[0].Price.ID
	tier, limit := h.tierFor(priceID)

	// If the subscription isn't active/trialing, deactivate.
	active := sub.Status == stripego.SubscriptionStatusActive ||
		sub.Status == stripego.SubscriptionStatusTrialing
	if !active || tier == store.TierNone {
		return h.db.DeactivateByStripeCustomer(sub.Customer.ID)
	}

	// Stripe API version 2025-03-31 (Basil) moved `current_period_end` from the
	// Subscription to the SubscriptionItem. If the account's API version is
	// >= Basil, `sub.CurrentPeriodEnd` arrives as 0 and we'd expire the
	// account immediately. Defensive fallback: fish the new field out of the
	// raw JSON (v79 Go SDK doesn't expose it as a struct field yet); if even
	// that fails, grant 35 days so a monthly subscriber isn't silently cut off.
	var until time.Time
	if sub.CurrentPeriodEnd > 0 {
		until = time.Unix(sub.CurrentPeriodEnd, 0).Add(3 * 24 * time.Hour)
	} else if itemEnd := itemPeriodEnd(evt.Data.Raw); itemEnd > 0 {
		until = time.Unix(itemEnd, 0).Add(3 * 24 * time.Hour)
	} else {
		log.Printf("subscription %s: no period_end in event; defaulting to 35d grace", sub.ID)
		until = time.Now().Add(35 * 24 * time.Hour)
	}

	return h.db.UpdateSubscriptionByStripeCustomer(sub.Customer.ID, tier, limit, until)
}

// itemPeriodEnd reaches into the raw event JSON to pull
// items.data[0].current_period_end — the post-Basil location of the field
// that moved off the Subscription object in the 2025-03-31 API version.
// Returns 0 if not present (pre-Basil events) or unparseable.
func itemPeriodEnd(raw json.RawMessage) int64 {
	var shim struct {
		Items struct {
			Data []struct {
				CurrentPeriodEnd int64 `json:"current_period_end"`
			} `json:"data"`
		} `json:"items"`
	}
	if err := json.Unmarshal(raw, &shim); err != nil {
		return 0
	}
	if len(shim.Items.Data) == 0 {
		return 0
	}
	return shim.Items.Data[0].CurrentPeriodEnd
}

func (h *Handler) handleSubscriptionDeleted(evt stripego.Event) error {
	var sub stripego.Subscription
	if err := json.Unmarshal(evt.Data.Raw, &sub); err != nil {
		return err
	}
	if sub.Customer == nil {
		return nil
	}
	return h.db.DeactivateByStripeCustomer(sub.Customer.ID)
}

func (h *Handler) tierFor(priceID string) (store.Tier, int) {
	switch priceID {
	case h.cfg.PriceBasicMonth, h.cfg.PriceBasicYear:
		return store.TierBasic, h.cfg.BasicDeviceLimit
	case h.cfg.PriceProMonth, h.cfg.PriceProYear:
		return store.TierPro, h.cfg.ProDeviceLimit
	default:
		return store.TierNone, 0
	}
}
