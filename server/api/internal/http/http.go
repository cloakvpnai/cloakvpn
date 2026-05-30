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
	"sync"
	"time"

	"github.com/stripe/stripe-go/v79/customer"

	"github.com/cloakvpn/api/internal/account"
	"github.com/cloakvpn/api/internal/regions"
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
	regs          *regions.Registry
	rc            *regions.Client
	accountSecret string
	defaultRegion string // region used when a request omits one (legacy app)
	subnet        string // per-region WireGuard subnet, e.g. 10.99.0.0/24

	// mu serializes the provision/revoke critical section so IP allocation
	// and the device-row write are atomic across concurrent requests.
	mu sync.Mutex
}

func NewDeviceHandler(db *store.DB, regs *regions.Registry, rc *regions.Client,
	accountSecret, defaultRegion, subnet string) *DeviceHandler {
	return &DeviceHandler{
		db:            db,
		regs:          regs,
		rc:            rc,
		accountSecret: accountSecret,
		defaultRegion: defaultRegion,
		subnet:        subnet,
	}
}

// provisionReq is the POST /v1/device body: the device's own public keys
// and the chosen region. region may be empty — a pre-multi-region app
// build omits it — in which case the handler's defaultRegion is used.
type provisionReq struct {
	WGPubkey        string `json:"wg_pubkey"`
	RosenpassPubkey string `json:"rosenpass_pubkey"`
	Region          string `json:"region"`
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

// allocIP picks a free tunnel IP within a region. The caller must hold
// h.mu so the choice cannot race another provision in the same region.
func (h *DeviceHandler) allocIP(regionID string) (string, error) {
	used, err := h.db.DeviceIPsInRegion(regionID)
	if err != nil {
		return "", err
	}
	return regions.NextFreeIP(used, h.subnet)
}

func (h *DeviceHandler) writeProvision(w http.ResponseWriter, cfg *wg.ClientConfig,
	tier store.Tier, dev store.Device) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(provisionResp{Config: cfg, Tier: tier, Device: dev})
}

// leastRecentlySeen returns the device with the oldest last_seen — the best
// eviction candidate when a new device needs a slot. devs must be non-empty.
func leastRecentlySeen(devs []store.Device) store.Device {
	lru := devs[0]
	for _, d := range devs[1:] {
		if d.LastSeen.Before(lru.LastSeen) {
			lru = d
		}
	}
	return lru
}

// removeDevice returns devs without the row identified by id.
func removeDevice(devs []store.Device, id int64) []store.Device {
	out := make([]store.Device, 0, len(devs))
	for _, d := range devs {
		if d.ID != id {
			out = append(out, d)
		}
	}
	return out
}

// evict frees a device slot: revoke the peer on its concentrator (best
// effort — a stale peer is harmless and must not block reclaiming the
// slot), then delete the row. Caller holds h.mu.
func (h *DeviceHandler) evict(dev store.Device) error {
	if reg, ok := h.regs.Get(dev.Region); ok {
		if err := h.rc.Revoke(reg, dev.WGPubkey); err != nil {
			log.Printf("evict: revoke %s peer: %v", dev.Region, err)
		}
	}
	return h.db.DeleteDevice(dev.ID, dev.AccountID)
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

	// The device generates its own WireGuard + Rosenpass keypairs and sends
	// only the public keys. The Rosenpass public key is ~700 KB base64,
	// hence the 2 MiB cap.
	var req provisionReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2<<20)).Decode(&req); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	if req.WGPubkey == "" || req.RosenpassPubkey == "" {
		http.Error(w, "wg_pubkey and rosenpass_pubkey required", http.StatusBadRequest)
		return
	}
	regionID := req.Region
	if regionID == "" {
		regionID = h.defaultRegion // pre-multi-region app build omits region
	}
	reg, ok := h.regs.Get(regionID)
	if !ok {
		http.Error(w, "unknown region", http.StatusBadRequest)
		return
	}

	// Serialize the provision critical section: IP allocation through the
	// device-row write must be atomic within a region.
	h.mu.Lock()
	defer h.mu.Unlock()

	// The app keeps a stable WireGuard keypair, so a reconnect, a reinstall
	// that kept app data, an account-number change, or a region switch all
	// re-send the same wg_pubkey. There is one row per device — find it.
	known, err := h.db.DeviceByPubkey(req.WGPubkey)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		log.Printf("device lookup: %v", err)
		http.Error(w, "server", http.StatusInternalServerError)
		return
	}

	if known != nil {
		// Hand the device row to whichever account just authenticated — the
		// same phone may have switched account numbers.
		if known.AccountID != acct.ID {
			if err := h.db.ReassignDevice(known.ID, acct.ID); err != nil {
				log.Printf("device reassign: %v", err)
				http.Error(w, "server", http.StatusInternalServerError)
				return
			}
			known.AccountID = acct.ID
		}

		// Mark the device active so the self-cleaning limit never picks an
		// in-use device as the eviction victim. Non-fatal on error.
		if err := h.db.TouchDevice(known.ID); err != nil {
			log.Printf("touch device %d: %v", known.ID, err)
		}

		if known.Region == regionID {
			// Same region — re-provision in place at the existing IP. Every
			// regionsvc peer operation is idempotent.
			cfg, err := h.rc.Provision(reg, req.WGPubkey, req.RosenpassPubkey, known.WGIP)
			if err != nil {
				log.Printf("reprovision %s: %v", regionID, err)
				http.Error(w, "provision failed", http.StatusBadGateway)
				return
			}
			h.writeProvision(w, cfg, acct.Tier, *known)
			return
		}

		// Region switch — one active region per device. ORDERING IS
		// CRITICAL: provision the NEW box and send the response BEFORE
		// revoking the old peer.
		//
		// The client's provision request travels over the OLD region's
		// tunnel — iOS host-app sockets cannot bypass the tunnel under
		// includeAllNetworks=true, so the client's excludedRoutes
		// control-plane carve-out is a no-op (the same NECP restriction
		// that forces rosenpass through the NE). If we revoke the old
		// peer first (the previous behavior), that tunnel goes dark and
		// the in-flight HTTP response is killed before it reaches the
		// device — surfaced client-side as "Couldn't reach Lattice."
		// The failure is timing-dependent: nearby regions provision fast
		// enough that the response sometimes wins the race, but distant
		// regions (e.g. za1 Johannesburg) are slow to provision and lose
		// it every time. Revoking AFTER the response — deferred and
		// best-effort — keeps the old tunnel alive until the device has
		// its new config and has moved over. A briefly-lingering old peer
		// is harmless: a device only ever connects to one region at once.
		oldRegionID := known.Region
		ip, err := h.allocIP(regionID)
		if err != nil {
			log.Printf("alloc ip %s: %v", regionID, err)
			http.Error(w, "server", http.StatusInternalServerError)
			return
		}
		cfg, err := h.rc.Provision(reg, req.WGPubkey, req.RosenpassPubkey, ip)
		if err != nil {
			log.Printf("provision %s: %v", regionID, err)
			http.Error(w, "provision failed", http.StatusBadGateway)
			return
		}
		if err := h.db.UpdateDeviceRegion(known.ID, regionID, ip); err != nil {
			log.Printf("update device region: %v", err)
			http.Error(w, "server", http.StatusInternalServerError)
			return
		}
		known.Region, known.WGIP = regionID, ip
		h.writeProvision(w, cfg, acct.Tier, *known)

		// Tear down the old region's peer only after the response is on
		// the wire. Deferred + best-effort so it can never kill the
		// in-flight response; the device keeps routing over the old
		// tunnel until it reconnects to the new region.
		//
		// RE-VALIDATE before revoking: a device that switches away and
		// back within the delay window (A→B→A) would otherwise have its
		// now-current region's peer torn down by this stale timer —
		// revoking the very peer it just reconnected to, which restarts
		// that box's rosenpass and breaks the live connection. So look
		// the device up again and skip the revoke if it has returned to
		// oldRegionID (or the row was reassigned/removed meanwhile).
		if _, ok := h.regs.Get(oldRegionID); ok {
			wgPubkey := req.WGPubkey
			devID := known.ID
			go func() {
				time.Sleep(8 * time.Second)
				cur, err := h.db.DeviceByPubkey(wgPubkey)
				if err != nil || cur == nil || cur.ID != devID {
					return // row gone or reassigned — leave it alone
				}
				if cur.Region == oldRegionID {
					return // device came back to the old region; keep its peer
				}
				oldReg, ok := h.regs.Get(oldRegionID)
				if !ok {
					return
				}
				if err := h.rc.Revoke(oldReg, wgPubkey); err != nil {
					log.Printf("deferred revoke old region %s: %v", oldRegionID, err)
				}
			}()
		}
		return
	}

	// New device. The per-account device limit applies only here — a
	// re-provision or region switch never consumes a fresh slot.
	existing, err := h.db.DevicesForAccount(acct.ID)
	if err != nil {
		log.Printf("devices for account: %v", err)
		http.Error(w, "server", http.StatusInternalServerError)
		return
	}
	// Self-cleaning limit. A device row is bound to the app's WireGuard
	// keypair, which is regenerated on every reinstall or "clear data" — so
	// one physical phone legitimately piles up rows over time. Rather than
	// 403 the customer once that reaches the tier cap (locking them out of
	// their own phone), evict the least-recently-seen device to make room.
	// The cap still bounds how many *actively used* devices coexist — the
	// real tier limit — and the loop also absorbs an over-limit account
	// left behind by a Pro→Basic downgrade.
	for acct.DeviceLimit > 0 && len(existing) >= acct.DeviceLimit {
		victim := leastRecentlySeen(existing)
		if err := h.evict(victim); err != nil {
			log.Printf("evict device %d: %v", victim.ID, err)
			http.Error(w, "server", http.StatusInternalServerError)
			return
		}
		log.Printf("device limit: evicted least-recently-seen device %d (account %d)",
			victim.ID, acct.ID)
		existing = removeDevice(existing, victim.ID)
	}
	ip, err := h.allocIP(regionID)
	if err != nil {
		log.Printf("alloc ip %s: %v", regionID, err)
		http.Error(w, "server", http.StatusInternalServerError)
		return
	}
	cfg, err := h.rc.Provision(reg, req.WGPubkey, req.RosenpassPubkey, ip)
	if err != nil {
		log.Printf("provision %s: %v", regionID, err)
		http.Error(w, "provision failed", http.StatusBadGateway)
		return
	}
	dev, err := h.db.AddDevice(acct.ID, regionID, req.WGPubkey, ip)
	if err != nil {
		// Roll back the peer so we don't leak capacity on the box.
		log.Printf("add device: %v", err)
		_ = h.rc.Revoke(reg, req.WGPubkey)
		http.Error(w, "server", http.StatusInternalServerError)
		return
	}
	h.writeProvision(w, cfg, acct.Tier, *dev)
}

// revoke frees a device slot: DELETE /v1/device?id=<device-id>, authed by
// the account number. Removes the peer from its region, then the DB row.
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

	// Same critical section as create() — serialize all device mutations.
	h.mu.Lock()
	defer h.mu.Unlock()

	dev, err := h.db.DeviceByID(id, acct.ID)
	if errors.Is(err, store.ErrNotFound) {
		http.Error(w, "device not found", http.StatusNotFound)
		return
	}
	if err != nil {
		http.Error(w, "server", http.StatusInternalServerError)
		return
	}
	// Remove the peer from its region's concentrator. A legacy row whose
	// region is unknown (region='') just has its DB row dropped.
	if reg, ok := h.regs.Get(dev.Region); ok {
		if err := h.rc.Revoke(reg, dev.WGPubkey); err != nil {
			log.Printf("revoke %s: %v", dev.Region, err)
			http.Error(w, "revoke failed", http.StatusBadGateway)
			return
		}
	}
	if err := h.db.DeleteDevice(dev.ID, acct.ID); err != nil {
		log.Printf("delete device: %v", err)
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
	// The website welcome page (latticevpn.ai) fetches this cross-origin.
	// A plain GET with no custom headers is a CORS "simple request", so
	// this response header alone is enough — no preflight to handle.
	w.Header().Set("Access-Control-Allow-Origin", "https://latticevpn.ai")
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
