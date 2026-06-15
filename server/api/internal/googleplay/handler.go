package googleplay

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"time"

	"github.com/cloakvpn/api/internal/account"
	"github.com/cloakvpn/api/internal/store"
)

// Config wires product→tier mapping and the account-number HMAC secret. The
// product IDs must match the subscription products created in the Play Console.
type Config struct {
	PackageName string // ai.latticevpn.android

	ProductBasicMonthly string
	ProductBasicYearly  string
	ProductProMonthly   string
	ProductProYearly    string

	BasicDeviceLimit int
	ProDeviceLimit   int

	AccountNumberSecret string

	// NotificationSecret, when non-empty, is required as a ?token= query
	// parameter on the RTDN endpoint — a shared secret embedded in the
	// Pub/Sub push URL so only Google's push can reach it. Optional but
	// recommended; leave empty to disable the check.
	NotificationSecret string

	// Grace added to Google's exact expiry so a brief renewal lag doesn't cut
	// a paying subscriber off mid-cycle (mirrors the Stripe/Apple paths).
	Grace time.Duration
}

// Handler serves the Google Play Billing endpoints. It is constructed only
// when a Developer API client is available (a service account is configured).
type Handler struct {
	cfg Config
	db  *store.DB
	cl  *Client
}

func NewHandler(cfg Config, db *store.DB, cl *Client) *Handler {
	if cfg.Grace == 0 {
		cfg.Grace = 24 * time.Hour
	}
	return &Handler{cfg: cfg, db: db, cl: cl}
}

func (h *Handler) tierFor(productID string) (store.Tier, int) {
	switch productID {
	case h.cfg.ProductBasicMonthly, h.cfg.ProductBasicYearly:
		return store.TierBasic, h.cfg.BasicDeviceLimit
	case h.cfg.ProductProMonthly, h.cfg.ProductProYearly:
		return store.TierPro, h.cfg.ProDeviceLimit
	default:
		return store.TierNone, 0
	}
}

// ---- POST /v1/googleplay -------------------------------------------------

type verifyReq struct {
	// PurchaseToken is the token returned by the Play Billing Library after a
	// successful purchase (Purchase.getPurchaseToken()).
	PurchaseToken string `json:"purchase_token"`
	// Restore=true means the app has no local copy of the account number
	// (fresh install / new device) and needs the server to re-issue one.
	Restore bool `json:"restore"`
}

type verifyResp struct {
	// AccountNumber is non-empty only when the server minted or re-issued a
	// number this call; on a plain renewal re-verify it's empty and the app
	// keeps the number it already holds.
	AccountNumber string `json:"account_number,omitempty"`
	Tier          string `json:"tier"`
	ActiveUntil   string `json:"active_until"`
}

// Verify backs POST /v1/googleplay. The app posts its purchase token; we query
// the Play Developer API for the authoritative subscription state, map the
// product to a tier, and mint or extend the corresponding account, returning a
// fresh account number when one is created or re-issued.
func (h *Handler) Verify(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		http.Error(w, "read body", http.StatusBadRequest)
		return
	}
	var req verifyReq
	if err := json.Unmarshal(body, &req); err != nil || req.PurchaseToken == "" {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	sub, err := h.cl.GetSubscription(r.Context(), req.PurchaseToken)
	if err != nil {
		log.Printf("googleplay verify: %v", err)
		http.Error(w, "invalid purchase", http.StatusBadRequest)
		return
	}

	tier, limit := h.tierFor(sub.ProductID)
	if tier == store.TierNone {
		log.Printf("googleplay verify: unknown product %q", sub.ProductID)
		http.Error(w, "unknown product", http.StatusBadRequest)
		return
	}
	if !sub.Entitled() {
		http.Error(w, "subscription not active", http.StatusPaymentRequired)
		return
	}
	until := sub.Expiry.Add(h.cfg.Grace)

	// Plan change / resubscribe: Google issued this token to replace an older
	// one. Move any existing account row onto the new token so the chain stays
	// a single account (no-op if we never minted under the old token).
	if sub.LinkedPurchaseToken != "" {
		if err := h.db.RelinkGooglePlayToken(sub.LinkedPurchaseToken, req.PurchaseToken); err != nil {
			log.Printf("googleplay verify: relink: %v", err)
		}
	}

	resp := verifyResp{Tier: string(tier), ActiveUntil: until.UTC().Format(time.RFC3339)}

	_, err = h.db.AccountByGooglePlayToken(req.PurchaseToken)
	switch {
	case errors.Is(err, store.ErrNotFound):
		// First purchase → mint a brand-new account number.
		number, gerr := account.Generate()
		if gerr != nil {
			http.Error(w, "server", http.StatusInternalServerError)
			return
		}
		hash := account.Hash(number, h.cfg.AccountNumberSecret)
		if _, cerr := h.db.CreateAccountGooglePlay(hash, req.PurchaseToken, tier, limit, until); cerr != nil {
			log.Printf("googleplay verify: create account: %v", cerr)
			http.Error(w, "server", http.StatusInternalServerError)
			return
		}
		log.Printf("googleplay: minted account (tier=%s) for purchaseToken %s…", tier, short(req.PurchaseToken))
		resp.AccountNumber = number

	case err == nil:
		// Existing subscription → refresh tier/expiry.
		if uerr := h.db.UpdateSubscriptionByGooglePlayToken(req.PurchaseToken, tier, limit, until); uerr != nil {
			log.Printf("googleplay verify: update sub: %v", uerr)
			http.Error(w, "server", http.StatusInternalServerError)
			return
		}
		if req.Restore {
			// App has no local number → re-issue one (no-plaintext policy
			// means we can't return the original). Subscription identity is
			// unchanged; the previously-issued number stops working.
			number, gerr := account.Generate()
			if gerr != nil {
				http.Error(w, "server", http.StatusInternalServerError)
				return
			}
			hash := account.Hash(number, h.cfg.AccountNumberSecret)
			if herr := h.db.UpdateAccountHashByGooglePlayToken(req.PurchaseToken, hash); herr != nil {
				log.Printf("googleplay verify: re-issue: %v", herr)
				http.Error(w, "server", http.StatusInternalServerError)
				return
			}
			resp.AccountNumber = number
			log.Printf("googleplay: re-issued account number on restore for purchaseToken %s…", short(req.PurchaseToken))
		}

	default:
		log.Printf("googleplay verify: lookup: %v", err)
		http.Error(w, "server", http.StatusInternalServerError)
		return
	}

	// Acknowledge the purchase so Google does not auto-refund it (3-day
	// window). Best-effort: the entitlement is already granted, and a retry
	// path (RTDN re-verify) will re-acknowledge if this fails.
	if !sub.Acknowledged {
		if aerr := h.cl.Acknowledge(r.Context(), sub.ProductID, req.PurchaseToken); aerr != nil {
			log.Printf("googleplay verify: acknowledge: %v", aerr)
		}
	}

	writeJSON(w, resp)
}

// ---- POST /v1/googleplay/notifications (Real-time Developer Notifications) -

// Notifications backs POST /v1/googleplay/notifications. Google Cloud Pub/Sub
// pushes a base64 DeveloperNotification on every subscription lifecycle event.
// We re-query the Developer API for the authoritative state (never trusting
// the notification type alone) and keep the account's tier/expiry in sync.
// Always 200 on a well-formed payload so Pub/Sub stops retrying.
func (h *Handler) Notifications(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	// Optional shared-secret gate: the Pub/Sub push URL carries ?token=…
	if h.cfg.NotificationSecret != "" {
		if r.URL.Query().Get("token") != h.cfg.NotificationSecret {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		http.Error(w, "read body", http.StatusBadRequest)
		return
	}
	n, err := DecodeNotification(body)
	if err != nil {
		log.Printf("googleplay notification: %v", err)
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	// A test notification (sent from the Play Console) carries no subscription.
	if n.SubscriptionNotification == nil {
		if n.TestNotification != nil {
			log.Printf("googleplay notification: test ping ok")
		}
		w.WriteHeader(http.StatusOK)
		return
	}

	token := n.SubscriptionNotification.PurchaseToken
	sub, err := h.cl.GetSubscription(r.Context(), token)
	if err != nil {
		// Can't reach the authoritative source — 500 so Pub/Sub retries later.
		log.Printf("googleplay notification: get sub: %v", err)
		http.Error(w, "server", http.StatusInternalServerError)
		return
	}

	if sub.LinkedPurchaseToken != "" {
		if rerr := h.db.RelinkGooglePlayToken(sub.LinkedPurchaseToken, token); rerr != nil {
			log.Printf("googleplay notification: relink: %v", rerr)
		}
	}

	tier, limit := h.tierFor(sub.ProductID)
	until := sub.Expiry.Add(h.cfg.Grace)

	if sub.Entitled() && tier != store.TierNone {
		// Refreshes an existing row; affects 0 rows if the client hasn't run
		// its verify call yet (which will mint the account and return the
		// number to the user). We never mint from a notification because there
		// is no client waiting to receive the freshly-minted number.
		if uerr := h.db.UpdateSubscriptionByGooglePlayToken(token, tier, limit, until); uerr != nil {
			log.Printf("googleplay notification type=%d: update: %v", n.SubscriptionNotification.NotificationType, uerr)
			http.Error(w, "server", http.StatusInternalServerError)
			return
		}
		log.Printf("googleplay notification type=%d: refreshed purchaseToken %s… (tier=%s)",
			n.SubscriptionNotification.NotificationType, short(token), tier)
	} else {
		if derr := h.db.DeactivateByGooglePlayToken(token); derr != nil {
			log.Printf("googleplay notification type=%d: deactivate: %v", n.SubscriptionNotification.NotificationType, derr)
			http.Error(w, "server", http.StatusInternalServerError)
			return
		}
		log.Printf("googleplay notification type=%d: deactivated purchaseToken %s… (state=%s)",
			n.SubscriptionNotification.NotificationType, short(token), sub.State)
	}

	w.WriteHeader(http.StatusOK)
}

// short returns a log-safe prefix of a purchase token (they're long and we
// don't want full tokens in logs).
func short(s string) string {
	if len(s) > 12 {
		return s[:12]
	}
	return s
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
