// Package http wires HTTP routes for the API. Kept small on purpose: a
// health check, the Stripe webhook (owned by internal/stripe), the device
// provisioning endpoint, an account lookup, and the welcome-page
// account-number lookup.
//
// Auth model: there are no user accounts. /v1/device and /v1/account are
// authenticated by the customer's account number, sent as
// `Authorization: Bearer <account-number>`. The server hashes it (package
// account) and matches against the stored HMAC. See
// docs/BILLING_INTEGRATION.md.
package http

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/stripe/stripe-go/v79/customer"

	"github.com/cloakvpn/api/internal/account"
	"github.com/cloakvpn/api/internal/store"
	"github.com/cloakvpn/api/internal/wg"
)

// Middleware is the single HTTP middleware chain for the server. We keep it
// minimal: a panic catcher, a request logger that does NOT log the path with
// query string (which could include tokens), and a small security header set.
func Middleware(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				log.Printf("panic: %v", rec)
				http.Error(w, "server", http.StatusInternalServerError)
			}
		}()
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Strict-Transport-Security", "max-age=63072000; includeSubDomains")
		start := time.Now()
		h.ServeHTTP(w, r)
		// Log method + path only — no IPs, no UAs, no query strings.
		log.Printf("%s %s %s", r.Method, stripQuery(r.URL.Path), time.Since(start))
	})
}

func stripQuery(p string) string {
	if i := strings.IndexByte(p, '?'); i >= 0 {
		return p[:i]
	}
	return p
}

func Health(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"ok":true}`))
}

// bearerNumber extracts the account number from an `Authorization: Bearer
// <account-number>` header. Returns "" if absent or malformed.
func bearerNumber(r *http.Request) string {
	const prefix = "Bearer "
	h := r.Header.Get("Authorization")
	if strings.HasPrefix(h, prefix) {
		return strings.TrimSpace(h[len(prefix):])
	}
	return ""
}

// ---- /v1/device ----

type DeviceHandler struct {
	db            *store.DB
	wgc           *wg.Controller
	accountSecret string
}

func NewDeviceHandler(db *store.DB, wgc *wg.Controller, accountSecret string) *DeviceHandler {
	return &DeviceHandler{db: db, wgc: wgc, accountSecret: accountSecret}
}

type provisionResp struct {
	Config *wg.ClientConfig `json:"config"`
	Tier   store.Tier       `json:"tier"`
	Device store.Device     `json:"device"`
}

func (h *DeviceHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodPost:
		h.create(w, r)
	case http.MethodDelete:
		h.revoke(w, r)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// authAccount resolves the account number from the Authorization header
// and looks up the account. On any failure it writes the HTTP error and
// returns nil, so callers just `if acct == nil { return }`.
func (h *DeviceHandler) authAccount(w http.ResponseWriter, r *http.Request) *store.Account {
	num := bearerNumber(r)
	if num == "" {
		http.Error(w, "missing account number", http.StatusUnauthorized)
		return nil
	}
	acct, err := h.db.AccountByNumberHash(account.Hash(num, h.accountSecret))
	if errors.Is(err, store.ErrNotFound) {
		http.Error(w, "unknown account", http.StatusUnauthorized)
		return nil
	}
	if err != nil {
		log.Printf("account lookup: %v", err)
		http.Error(w, "server", http.StatusInternalServerError)
		return nil
	}
	return acct
}

func (h *DeviceHandler) create(w http.ResponseWriter, r *http.Request) {
	acct := h.authAccount(w, r)
	if acct == nil {
		return
	}
	if acct.Tier == store.TierNone || time.Now().After(acct.ActiveUntil) {
		http.Error(w, "no active subscription", http.StatusPaymentRequired)
		return
	}

	existing, err := h.db.DevicesForAccount(acct.ID)
	if err != nil {
		http.Error(w, "server", http.StatusInternalServerError)
		return
	}
	if len(existing) >= acct.DeviceLimit {
		http.Error(w, "device limit reached", http.StatusForbidden)
		return
	}

	used := make([]string, 0, len(existing))
	for _, d := range existing {
		used = append(used, d.WGIP)
	}
	cfg, err := h.wgc.Provision(used)
	if err != nil {
		log.Printf("wg provision: %v", err)
		http.Error(w, "provision failed", http.StatusInternalServerError)
		return
	}
	dev, err := h.db.AddDevice(acct.ID, cfg.InterfacePublicKey, cfg.AssignedIP)
	if err != nil {
		// Roll back the wg + rosenpass peer so we don't leak capacity. NB:
		// revoke the CLIENT's pubkey, not cfg.PeerPublicKey (the server's).
		_ = h.wgc.Revoke(cfg.InterfacePublicKey)
		http.Error(w, "server", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(provisionResp{Config: cfg, Tier: acct.Tier, Device: *dev})
}

// revoke frees a device slot: DELETE /v1/device?id=<device-id>, authed by
// the account number. Removes the wg + rosenpass peer, then the DB row.
func (h *DeviceHandler) revoke(w http.ResponseWriter, r *http.Request) {
	acct := h.authAccount(w, r)
	if acct == nil {
		return
	}
	id, err := strconv.ParseInt(r.URL.Query().Get("id"), 10, 64)
	if err != nil || id <= 0 {
		http.Error(w, "device id required", http.StatusBadRequest)
		return
	}
	dev, err := h.db.DeviceByID(id, acct.ID)
	if errors.Is(err, store.ErrNotFound) {
		http.Error(w, "device not found", http.StatusNotFound)
		return
	}
	if err != nil {
		http.Error(w, "server", http.StatusInternalServerError)
		return
	}
	if err := h.wgc.Revoke(dev.WGPubkey); err != nil {
		log.Printf("wg revoke: %v", err)
		http.Error(w, "revoke failed", http.StatusInternalServerError)
		return
	}
	if err := h.db.DeleteDevice(dev.ID, acct.ID); err != nil {
		http.Error(w, "server", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- /v1/account ----

type AccountHandler struct {
	db            *store.DB
	accountSecret string
}

func NewAccountHandler(db *store.DB, accountSecret string) *AccountHandler {
	return &AccountHandler{db: db, accountSecret: accountSecret}
}

type deviceInfo struct {
	ID        int64     `json:"id"`
	IP        string    `json:"ip"`
	CreatedAt time.Time `json:"created_at"`
}

type accountResp struct {
	Tier        store.Tier   `json:"tier"`
	DeviceLimit int          `json:"device_limit"`
	DeviceCount int          `json:"device_count"`
	ActiveUntil time.Time    `json:"active_until"`
	Devices     []deviceInfo `json:"devices"`
}

func (h *AccountHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	num := bearerNumber(r)
	if num == "" {
		http.Error(w, "missing account number", http.StatusUnauthorized)
		return
	}
	acct, err := h.db.AccountByNumberHash(account.Hash(num, h.accountSecret))
	if errors.Is(err, store.ErrNotFound) {
		http.Error(w, "unknown account", http.StatusUnauthorized)
		return
	}
	if err != nil {
		http.Error(w, "server", http.StatusInternalServerError)
		return
	}
	devs, err := h.db.DevicesForAccount(acct.ID)
	if err != nil {
		http.Error(w, "server", http.StatusInternalServerError)
		return
	}
	out := accountResp{
		Tier:        acct.Tier,
		DeviceLimit: acct.DeviceLimit,
		DeviceCount: len(devs),
		ActiveUntil: acct.ActiveUntil,
		Devices:     make([]deviceInfo, 0, len(devs)),
	}
	for _, d := range devs {
		out.Devices = append(out.Devices, deviceInfo{ID: d.ID, IP: d.WGIP, CreatedAt: d.CreatedAt})
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)
}

// ---- /v1/account-number ----

// AccountNumberHandler backs GET /v1/account-number?session_id=… — used
// once by the website /welcome page to display the account number right
// after checkout. The plaintext number is not stored locally; it is read
// back from the Stripe customer metadata where the webhook wrote it.
type AccountNumberHandler struct{ db *store.DB }

func NewAccountNumberHandler(db *store.DB) *AccountNumberHandler {
	return &AccountNumberHandler{db: db}
}

type accountNumberResp struct {
	AccountNumber string `json:"account_number"`
}

func (h *AccountNumberHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	sessionID := r.URL.Query().Get("session_id")
	if sessionID == "" {
		http.Error(w, "session_id required", http.StatusBadRequest)
		return
	}
	acct, err := h.db.AccountBySession(sessionID)
	if errors.Is(err, store.ErrNotFound) {
		// The webhook may not have landed yet — the welcome page polls 404.
		http.Error(w, "not ready", http.StatusNotFound)
		return
	}
	if err != nil || acct.StripeCustomerID == "" {
		http.Error(w, "server", http.StatusInternalServerError)
		return
	}
	cust, err := customer.Get(acct.StripeCustomerID, nil)
	if err != nil {
		log.Printf("stripe customer get %s: %v", acct.StripeCustomerID, err)
		http.Error(w, "server", http.StatusInternalServerError)
		return
	}
	number := cust.Metadata[account.MetadataKey]
	if number == "" {
		http.Error(w, "account number unavailable", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(accountNumberResp{AccountNumber: number})
}
