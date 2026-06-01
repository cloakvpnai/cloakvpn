package appleiap

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
// product IDs must match the auto-renewable subscriptions created in App
// Store Connect.
type Config struct {
	BundleID string // ai.cloakvpn.CloakVPN — every transaction must match

	ProductBasicMonthly string
	ProductBasicYearly  string
	ProductProMonthly   string
	ProductProYearly    string

	BasicDeviceLimit int
	ProDeviceLimit   int

	AccountNumberSecret string

	// Grace added to Apple's exact expiry so a brief renewal lag doesn't cut
	// a paying subscriber off mid-cycle (mirrors the Stripe path's grace).
	Grace time.Duration
}

type Handler struct {
	cfg Config
	db  *store.DB
}

func NewHandler(cfg Config, db *store.DB) *Handler {
	if cfg.Grace == 0 {
		cfg.Grace = 24 * time.Hour
	}
	return &Handler{cfg: cfg, db: db}
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

// ---- POST /v1/iap --------------------------------------------------------

type verifyReq struct {
	// SignedTransaction is StoreKit 2's Transaction.jwsRepresentation.
	SignedTransaction string `json:"signed_transaction"`
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

// Verify backs POST /v1/iap. The app posts its signed StoreKit transaction;
// we verify it against Apple's signature, map the product to a tier, and mint
// or extend the corresponding account, returning a fresh account number when
// one is created or re-issued.
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
	if err := json.Unmarshal(body, &req); err != nil || req.SignedTransaction == "" {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	tx, err := VerifyTransaction(req.SignedTransaction)
	if err != nil {
		log.Printf("iap verify: %v", err)
		http.Error(w, "invalid transaction", http.StatusBadRequest)
		return
	}
	if tx.BundleID != h.cfg.BundleID {
		log.Printf("iap verify: bundleId mismatch %q != %q", tx.BundleID, h.cfg.BundleID)
		http.Error(w, "wrong app", http.StatusBadRequest)
		return
	}

	tier, limit := h.tierFor(tx.ProductID)
	if tier == store.TierNone {
		log.Printf("iap verify: unknown product %q", tx.ProductID)
		http.Error(w, "unknown product", http.StatusBadRequest)
		return
	}

	until := tx.ExpiresAt().Add(h.cfg.Grace)
	// Refunded/revoked or already expired → not entitled.
	if tx.Revoked() || until.Before(time.Now()) {
		http.Error(w, "subscription not active", http.StatusPaymentRequired)
		return
	}

	_, err = h.db.AccountByAppleTxn(tx.OriginalTransactionID)
	switch {
	case errors.Is(err, store.ErrNotFound):
		// First purchase → mint a brand-new account number.
		number, err := account.Generate()
		if err != nil {
			http.Error(w, "server", http.StatusInternalServerError)
			return
		}
		hash := account.Hash(number, h.cfg.AccountNumberSecret)
		if _, err := h.db.CreateAccountApple(hash, tx.OriginalTransactionID, tier, limit, until); err != nil {
			log.Printf("iap verify: create account: %v", err)
			http.Error(w, "server", http.StatusInternalServerError)
			return
		}
		log.Printf("iap: minted account (tier=%s) for originalTxn %s", tier, tx.OriginalTransactionID)
		writeJSON(w, verifyResp{AccountNumber: number, Tier: string(tier), ActiveUntil: until.UTC().Format(time.RFC3339)})

	case err == nil:
		// Existing subscription → refresh tier/expiry.
		if err := h.db.UpdateSubscriptionByAppleTxn(tx.OriginalTransactionID, tier, limit, until); err != nil {
			log.Printf("iap verify: update sub: %v", err)
			http.Error(w, "server", http.StatusInternalServerError)
			return
		}
		resp := verifyResp{Tier: string(tier), ActiveUntil: until.UTC().Format(time.RFC3339)}
		if req.Restore {
			// App has no local number → re-issue one (no-plaintext policy
			// means we can't return the original). Subscription identity is
			// unchanged; the previously-issued number stops working.
			number, err := account.Generate()
			if err != nil {
				http.Error(w, "server", http.StatusInternalServerError)
				return
			}
			hash := account.Hash(number, h.cfg.AccountNumberSecret)
			if err := h.db.UpdateAccountHashByAppleTxn(tx.OriginalTransactionID, hash); err != nil {
				log.Printf("iap verify: re-issue: %v", err)
				http.Error(w, "server", http.StatusInternalServerError)
				return
			}
			resp.AccountNumber = number
			log.Printf("iap: re-issued account number on restore for originalTxn %s", tx.OriginalTransactionID)
		}
		writeJSON(w, resp)

	default:
		log.Printf("iap verify: lookup: %v", err)
		http.Error(w, "server", http.StatusInternalServerError)
	}
}

// ---- POST /v1/iap/notifications (App Store Server Notifications V2) -------

type notifyReq struct {
	SignedPayload string `json:"signedPayload"`
}

// Notifications backs POST /v1/iap/notifications. Apple posts subscription
// lifecycle events; we verify the signature and keep the account's
// tier/expiry in sync. Always 200 on a well-formed, verified payload so Apple
// stops retrying; 4xx/5xx only on bad signatures or DB errors.
func (h *Handler) Notifications(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		http.Error(w, "read body", http.StatusBadRequest)
		return
	}
	var req notifyReq
	if err := json.Unmarshal(body, &req); err != nil || req.SignedPayload == "" {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	n, tx, err := VerifyNotification(req.SignedPayload)
	if err != nil {
		log.Printf("iap notification: verify: %v", err)
		http.Error(w, "invalid notification", http.StatusBadRequest)
		return
	}
	if tx == nil {
		w.WriteHeader(http.StatusOK) // nothing actionable
		return
	}

	tier, limit := h.tierFor(tx.ProductID)

	switch n.NotificationType {
	case "SUBSCRIBED", "DID_RENEW", "OFFER_REDEEMED", "DID_CHANGE_RENEWAL_PREF", "RESUBSCRIBE":
		if tier == store.TierNone {
			break
		}
		until := tx.ExpiresAt().Add(h.cfg.Grace)
		if err := h.db.UpdateSubscriptionByAppleTxn(tx.OriginalTransactionID, tier, limit, until); err != nil {
			log.Printf("iap notification %s: update: %v", n.NotificationType, err)
			http.Error(w, "server", http.StatusInternalServerError)
			return
		}
		log.Printf("iap notification %s/%s: refreshed originalTxn %s (tier=%s)",
			n.NotificationType, n.Subtype, tx.OriginalTransactionID, tier)

	case "EXPIRED", "REFUND", "REVOKE", "GRACE_PERIOD_EXPIRED":
		if err := h.db.DeactivateByAppleTxn(tx.OriginalTransactionID); err != nil {
			log.Printf("iap notification %s: deactivate: %v", n.NotificationType, err)
			http.Error(w, "server", http.StatusInternalServerError)
			return
		}
		log.Printf("iap notification %s/%s: deactivated originalTxn %s",
			n.NotificationType, n.Subtype, tx.OriginalTransactionID)

	default:
		// DID_FAIL_TO_RENEW (still in grace), PRICE_INCREASE, TEST, etc. —
		// acknowledged, no state change.
		log.Printf("iap notification %s/%s: acknowledged (no-op)", n.NotificationType, n.Subtype)
	}

	w.WriteHeader(http.StatusOK)
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
