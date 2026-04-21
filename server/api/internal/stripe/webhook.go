// Package stripe handles Stripe webhook events. We care about three:
//
//   - checkout.session.completed  → first-time subscription, create account
//   - customer.subscription.updated → tier change or renewal (update active_until)
//   - customer.subscription.deleted → cancel/past-due (deactivate)
//
// The webhook signature is verified against STRIPE_WEBHOOK_SECRET. Anything
// else is rejected with 400. Events we don't care about return 200 so Stripe
// stops retrying.
package stripe

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"time"

	stripego "github.com/stripe/stripe-go/v79"
	"github.com/stripe/stripe-go/v79/webhook"

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
	email := sess.CustomerEmail
	if email == "" && sess.CustomerDetails != nil {
		email = sess.CustomerDetails.Email
	}
	if email == "" || sess.Customer == nil {
		// Nothing we can do without a customer handle + email.
		return nil
	}

	// Derive tier + limit + expiry from the first line item's price.
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

	until := time.Now().Add(35 * 24 * time.Hour) // refreshed on next subscription.updated
	_, err := h.db.UpsertAccountByStripeCustomer(sess.Customer.ID, email, tier, limit, until)
	return err
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

	until := time.Unix(sub.CurrentPeriodEnd, 0).Add(3 * 24 * time.Hour) // grace
	// We don't have the email here; re-use whatever we previously stored.
	// Look it up via the Stripe customer ID.
	// (For simplicity we call UpsertAccountByStripeCustomer only when we have
	//  the email, i.e. from checkout.session.completed. Here we just bump tier.)
	_, err := h.db.Exec(`UPDATE accounts
	                        SET tier = ?, device_limit = ?, active_until = ?
	                      WHERE stripe_customer_id = ?`,
		tier, limit, until, sub.Customer.ID)
	return err
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
