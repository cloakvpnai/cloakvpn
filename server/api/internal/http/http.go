// Package http wires HTTP routes for the API. Kept small on purpose — Phase 0
// only needs a health check, the Stripe webhook (owned by internal/stripe),
// a "give me a device config" endpoint, and an account lookup.
package http

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"time"

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

// ---- /v1/device ----

type DeviceHandler struct {
	db  *store.DB
	wgc *wg.Controller
}

func NewDeviceHandler(db *store.DB, wgc *wg.Controller) *DeviceHandler {
	return &DeviceHandler{db: db, wgc: wgc}
}

type provisionReq struct {
	Email string `json:"email"`
	Token string `json:"token"` // signed short-lived token from the app
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

func (h *DeviceHandler) create(w http.ResponseWriter, r *http.Request) {
	var req provisionReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	// TODO(phase-1): verify req.Token (HMAC'd magic-link token emailed at signup).
	if req.Email == "" {
		http.Error(w, "email required", http.StatusBadRequest)
		return
	}
	acct, err := h.db.AccountByEmail(req.Email)
	if err != nil {
		http.Error(w, "unknown account", http.StatusNotFound)
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
	dev, err := h.db.AddDevice(acct.ID, extractPub(cfg.InterfacePrivateKey, cfg), cfg.AssignedIP)
	if err != nil {
		// Roll back the wg peer so we don't leak capacity.
		_ = h.wgc.Revoke(cfg.PeerPublicKey)
		http.Error(w, "server", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(provisionResp{Config: cfg, Tier: acct.Tier, Device: *dev})
}

func (h *DeviceHandler) revoke(w http.ResponseWriter, r *http.Request) {
	// TODO(phase-1): authenticate via the signed email token, accept a device ID
	// to revoke, then call h.wgc.Revoke + h.db.DeleteDevice.
	http.Error(w, "not implemented", http.StatusNotImplemented)
}

// extractPub is a placeholder for deriving the WG pubkey from the private key
// we just generated. The real implementation stores the pubkey alongside the
// privkey in wg.Provision and returns it; for Phase 0 we treat PeerPublicKey
// as "server pub" and the client's pubkey is generated inside wg.Provision.
// This stub is intentional — the signature will evolve as Phase 0 firms up.
func extractPub(_ string, _ *wg.ClientConfig) string { return "REPLACE_WITH_CLIENT_WG_PUB" }

// ---- /v1/account ----

type AccountHandler struct{ db *store.DB }

func NewAccountHandler(db *store.DB) *AccountHandler { return &AccountHandler{db: db} }

type accountResp struct {
	Email       string     `json:"email"`
	Tier        store.Tier `json:"tier"`
	DeviceLimit int        `json:"device_limit"`
	DeviceCount int        `json:"device_count"`
	ActiveUntil time.Time  `json:"active_until"`
}

func (h *AccountHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	email := r.URL.Query().Get("email")
	if email == "" {
		http.Error(w, "email required", http.StatusBadRequest)
		return
	}
	acct, err := h.db.AccountByEmail(email)
	if err != nil {
		http.Error(w, "unknown account", http.StatusNotFound)
		return
	}
	devs, err := h.db.DevicesForAccount(acct.ID)
	if err != nil {
		http.Error(w, "server", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(accountResp{
		Email:       acct.Email,
		Tier:        acct.Tier,
		DeviceLimit: acct.DeviceLimit,
		DeviceCount: len(devs),
		ActiveUntil: acct.ActiveUntil,
	})
}
