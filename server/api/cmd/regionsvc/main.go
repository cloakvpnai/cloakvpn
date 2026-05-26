// Command regionsvc is the per-region provisioning service for Cloak VPN's
// multi-region topology (see docs/BILLING_INTEGRATION.md §7).
//
// One copy runs on every concentrator. It is a thin, authenticated HTTP
// wrapper around wg.Controller: the central cloakvpn-api validates the
// subscription and allocates an IP, then calls this service to actually
// add (or remove) the WireGuard + Rosenpass peer on THIS box. regionsvc
// owns no accounts and no database — all of that stays central.
//
// Auth: every request must carry `Authorization: Bearer <secret>` matching
// REGION_INTERNAL_SECRET, a single secret shared by the central API and
// every region (server-side env, file mode 0600, never committed). The
// provisioning payloads are public keys only — no private crypto material
// crosses the wire — but the secret gates who may mutate this box's
// WireGuard interface.
//
// It binds 127.0.0.1 by default; production exposes it to the central API
// over an authenticated channel (Caddy + TLS, or a private link), the same
// pattern as cloakvpn-api itself.
package main

import (
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/cloakvpn/api/internal/wg"
)

func main() {
	cfg := loadConfig()
	h := &handler{
		ctrl:   wg.NewController(cfg.wg),
		secret: cfg.secret,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/internal/provision", h.provision)
	mux.HandleFunc("/internal/revoke", h.revoke)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("ok\n"))
	})

	srv := &http.Server{
		Addr:        cfg.listen,
		Handler:     mux,
		ReadTimeout: 15 * time.Second,
		// Provisioning restarts the rosenpass service, which can take a few
		// seconds — give the write side generous headroom.
		WriteTimeout: 60 * time.Second,
	}
	log.Printf("regionsvc listening on %s", cfg.listen)
	log.Fatal(srv.ListenAndServe())
}

// ---- config --------------------------------------------------------------

type config struct {
	listen string
	secret string
	wg     wg.Config
}

func loadConfig() config {
	return config{
		listen: envOr("LISTEN_ADDR", "127.0.0.1:8090"),
		secret: mustEnv("REGION_INTERNAL_SECRET"),
		wg: wg.Config{
			Iface:      envOr("WG_IFACE", "wg0"),
			ServerPub:  mustWGPubkey("WG_SERVER_PUB"),
			Endpoint:   mustEndpoint("WG_ENDPOINT"), // e.g. madrid.cloakvpn.ai:51820
			// Public resolver, reached through the tunnel. The concentrator
			// runs NO DNS server, so the old 10.99.0.1 default (its own
			// in-tunnel address) black-holed every client lookup. Quad9 —
			// matches the pre-regionsvc add-peer.sh / cloak-api-server.py.
			DNS:        envOr("WG_DNS", "9.9.9.9, 2620:fe::fe"),
			AllowedIPs: envOr("WG_ALLOWED_IPS", "0.0.0.0/0, ::/0"),
			SubnetCIDR: envOr("WG_SUBNET", "10.99.0.0/24"),
		},
	}
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		log.Fatalf("missing required env var %s", k)
	}
	return v
}

// mustWGPubkey reads a required env var and validates it is a base64
// encoding of exactly 32 bytes — i.e. a real WireGuard public key.
//
// Catches the deployment-time mistake where the env file is left with a
// template placeholder like `<<< this box's server.pub`: regionsvc would
// otherwise embed the literal placeholder string into every ClientConfig
// it hands back to phones, producing apparently-successful provisions
// whose WireGuard tunnels can never come up. The on-box rosenpass service
// stays healthy, so no service-level alarm fires; only end users see
// "Connection failed". Fail loud at startup instead — see
// docs/HOTFIX_regionsvc-pubkey-placeholder-2026-05-26.md.
func mustWGPubkey(k string) string {
	v := mustEnv(k)
	raw, err := base64.StdEncoding.DecodeString(v)
	if err != nil {
		log.Fatalf("%s is not valid base64: %v — env file likely has a placeholder, not a real key (value=%q)", k, err, v)
	}
	if len(raw) != 32 {
		log.Fatalf("%s decoded to %d bytes, want 32 (a WireGuard public key) — env file likely has a placeholder, not a real key (value=%q)", k, len(raw), v)
	}
	return v
}

// mustEndpoint reads a required env var and validates it looks like a
// `host:port` pair. We don't resolve DNS here (the resolver may not be
// up yet at boot, and an unreachable hostname is a separate kind of
// failure worth diagnosing on its own); just check the shape.
func mustEndpoint(k string) string {
	v := mustEnv(k)
	host, port, ok := lastColonSplit(v)
	if !ok || host == "" || port == "" {
		log.Fatalf("%s is not in host:port form (value=%q)", k, v)
	}
	// Reject the obvious template-placeholder shape (matched leading/trailing
	// punctuation, angle brackets, ellipses).
	if strings.ContainsAny(v, "<>…") {
		log.Fatalf("%s looks like a template placeholder, not a real endpoint (value=%q)", k, v)
	}
	return v
}

// lastColonSplit splits on the LAST colon — IPv6 literals contain colons
// in the host part (e.g. `[fd42::1]:51820` or, with some tooling, the
// bare-bracket-less `fd42::1:51820`), so a simple `strings.Split(":")[0]`
// would corrupt them. The port is always after the final colon.
func lastColonSplit(s string) (host, port string, ok bool) {
	i := strings.LastIndex(s, ":")
	if i < 0 {
		return "", "", false
	}
	return s[:i], s[i+1:], true
}

// ---- handlers ------------------------------------------------------------

type handler struct {
	ctrl   *wg.Controller
	secret string
}

// provisionReq is the body of POST /internal/provision. The IP is
// pre-allocated by the central API from its database — regionsvc holds no
// device records, so it cannot allocate one itself.
type provisionReq struct {
	WGPubkey        string `json:"wg_pubkey"`
	RosenpassPubkey string `json:"rosenpass_pubkey"`
	IP              string `json:"ip"`
}

type revokeReq struct {
	WGPubkey string `json:"wg_pubkey"`
}

// authed reports whether the request carries the shared internal secret.
// Constant-time compare so a timing side-channel can't recover the secret.
func (h *handler) authed(r *http.Request) bool {
	const prefix = "Bearer "
	got := r.Header.Get("Authorization")
	if len(got) <= len(prefix) || got[:len(prefix)] != prefix {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(got[len(prefix):]), []byte(h.secret)) == 1
}

func (h *handler) provision(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !h.authed(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	// The Rosenpass public key is ~700 KB base64, hence the 2 MiB cap.
	var req provisionReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2<<20)).Decode(&req); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	if req.WGPubkey == "" || req.RosenpassPubkey == "" || req.IP == "" {
		http.Error(w, "wg_pubkey, rosenpass_pubkey and ip are required", http.StatusBadRequest)
		return
	}

	// IP is pinned via reuseIP — the central API already chose it from the
	// database, so regionsvc passes no usedIPs set of its own.
	cfg, err := h.ctrl.ProvisionWithKeys(nil, req.IP, req.WGPubkey, req.RosenpassPubkey)
	if err != nil {
		log.Printf("provision %s: %v", req.IP, err)
		http.Error(w, "provision failed", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(cfg)
}

func (h *handler) revoke(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !h.authed(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	var req revokeReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	if req.WGPubkey == "" {
		http.Error(w, "wg_pubkey required", http.StatusBadRequest)
		return
	}
	// Revoke is idempotent in wg.Controller — a missing peer is not an error.
	if err := h.ctrl.Revoke(req.WGPubkey); err != nil {
		log.Printf("revoke %s: %v", req.WGPubkey, err)
		http.Error(w, "revoke failed", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
