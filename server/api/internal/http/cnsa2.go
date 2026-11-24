package http

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/cloakvpn/api/internal/account"
	"github.com/cloakvpn/api/internal/cnsa2"
	"github.com/cloakvpn/api/internal/store"
)

// CNSA2Handler backs CNSA 2.0 mode enrollment:
//
//	POST   /v1/device/cnsa2/enroll        enroll a device, or renew its certificate
//	DELETE /v1/device/cnsa2?id=<id>       remove a device; its certificates are refused from then on
//	GET    /v1/cnsa2/gateways             gateways a signed-in app may use (account number)
//	POST   /v1/internal/cnsa2/gateway-cert a gateway renewing its own certificate (internal secret)
//	GET    /v1/internal/cnsa2/denylist    for gateways: serials to refuse (internal secret)
//
// The device makes its own ML-DSA-87 key and sends a certificate request.
// This handler decides whether the account may enroll it; the signing
// service checks the request and issues the certificate. No certificate
// authority key is ever on this server.
//
// The certificate names the device by a random identifier only, so a
// captured handshake does not reveal which customer it belongs to.
type CNSA2Handler struct {
	db             *store.DB
	signer         cnsa2.Signer
	accountSecret  string
	internalSecret string
	nameSuffix     string
	gateways       []cnsa2.Gateway
	// gatewayKeys maps a gateway name to the hash of the one key that may
	// renew its certificate.
	gatewayKeys map[string]string
	now         func() time.Time

	gwMu     sync.Mutex
	gwIssued map[string][]time.Time

	// mu makes the device-limit check, the signing call and the row writes
	// one step, so two enrollments cannot both take the last slot.
	mu sync.Mutex
}

// Certificates one device may be issued per hour. Renewal needs one every
// 20 days; this only stops a looping or hostile client from running up
// signing requests.
const cnsa2MaxIssuesPerHour = 6

func NewCNSA2Handler(db *store.DB, signer cnsa2.Signer, accountSecret, internalSecret, nameSuffix string,
	gateways []cnsa2.Gateway) *CNSA2Handler {
	keys := map[string]string{}
	public := make([]cnsa2.Gateway, len(gateways))
	for i, g := range gateways {
		if g.KeyHash != "" {
			keys[g.Name] = strings.ToLower(g.KeyHash)
		}
		g.KeyHash = "" // apps have no use for it
		public[i] = g
	}
	return &CNSA2Handler{db: db, signer: signer, accountSecret: accountSecret, internalSecret: internalSecret,
		nameSuffix: strings.Trim(nameSuffix, "."), gateways: public, gatewayKeys: keys, now: time.Now,
		gwIssued: map[string][]time.Time{}}
}

// internalAuth reports whether the request carries the region internal secret.
func (h *CNSA2Handler) internalAuth(r *http.Request) bool {
	const prefix = "Bearer "
	got := r.Header.Get("Authorization")
	return h.internalSecret != "" && strings.HasPrefix(got, prefix) &&
		subtle.ConstantTimeCompare([]byte(got[len(prefix):]), []byte(h.internalSecret)) == 1
}

// Certificates one gateway may be issued per hour. Renewal needs one about
// every two months.
const cnsa2MaxGatewayIssuesPerHour = 3

type cnsa2GatewayCertReq struct {
	Name    string `json:"name"`
	Request string `json:"request"`
}

type cnsa2GatewayCertResp struct {
	Certificate string `json:"certificate"`
	Issuing     string `json:"issuing"`
	Root        string `json:"root"`
	NotAfter    string `json:"not_after"`
}

// GatewayCert handles POST /v1/internal/cnsa2/gateway-cert: a gateway renewing
// its own certificate. The region internal secret gets a caller in the door,
// but a certificate is issued only for a listed gateway name and only for the
// key recorded for that name, so the secret alone cannot be used to obtain a
// certificate for any other key.
func (h *CNSA2Handler) GatewayCert(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !h.internalAuth(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	var req cnsa2GatewayCertReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2*cnsa2.MaxRequestBytes)).Decode(&req); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	der, err := base64.StdEncoding.DecodeString(req.Request)
	if err != nil {
		http.Error(w, "bad request encoding", http.StatusBadRequest)
		return
	}
	keyHash, err := cnsa2.RequestKeyHash(der)
	if err != nil {
		http.Error(w, "bad certificate request", http.StatusBadRequest)
		return
	}
	want, ok := h.gatewayKeys[req.Name]
	if !ok || subtle.ConstantTimeCompare([]byte(want), []byte(keyHash)) != 1 {
		log.Printf("cnsa2 gateway renewal refused for %q: name or key not registered", req.Name)
		http.Error(w, "gateway or key not registered", http.StatusForbidden)
		return
	}
	now := h.now()
	h.gwMu.Lock()
	recent := h.gwIssued[req.Name][:0]
	for _, t := range h.gwIssued[req.Name] {
		if now.Sub(t) < time.Hour {
			recent = append(recent, t)
		}
	}
	if len(recent) >= cnsa2MaxGatewayIssuesPerHour {
		h.gwIssued[req.Name] = recent
		h.gwMu.Unlock()
		http.Error(w, "too many requests", http.StatusTooManyRequests)
		return
	}
	h.gwIssued[req.Name] = append(recent, now)
	h.gwMu.Unlock()

	issued, err := h.signer.IssueGateway(r.Context(), req.Name, der)
	if errors.Is(err, cnsa2.ErrRejected) {
		http.Error(w, "certificate request rejected", http.StatusBadRequest)
		return
	}
	if err != nil {
		log.Printf("cnsa2 gateway renewal for %q: %v", req.Name, err)
		http.Error(w, "signing unavailable", http.StatusServiceUnavailable)
		return
	}
	log.Printf("cnsa2 gateway certificate issued: %s serial %s until %s", req.Name, issued.Serial, issued.NotAfter)
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(cnsa2GatewayCertResp{
		Certificate: issued.Certificate, Issuing: issued.Issuing, Root: issued.Root, NotAfter: issued.NotAfter})
}

func (h *CNSA2Handler) authAccount(w http.ResponseWriter, r *http.Request) *store.Account {
	num := bearerNumber(r)
	if num == "" {
		http.Error(w, "missing account number", http.StatusUnauthorized)
		return nil
	}
	acct, err := h.db.AccountByNumberHash(account.Hash(num, h.accountSecret))
	if errors.Is(err, store.ErrNotFound) {
		markNumberRecoverable(w)
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

type cnsa2EnrollReq struct {
	// Request is the device's PKCS#10 certificate request, base64 DER.
	Request string `json:"request"`
}

type cnsa2DeviceInfo struct {
	ID  int64  `json:"id"`
	UID string `json:"uid"`
}

type cnsa2EnrollResp struct {
	Certificate string          `json:"certificate"`
	Issuing     string          `json:"issuing"`
	Root        string          `json:"root"`
	NotAfter    string          `json:"not_after"`
	Device      cnsa2DeviceInfo `json:"device"`
	Gateways    []cnsa2.Gateway `json:"gateways"`
}

// Gateways handles GET /v1/cnsa2/gateways: the gateways a signed-in app may
// connect to, so it can follow new regions without asking for a certificate.
func (h *CNSA2Handler) Gateways(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if acct := h.authAccount(w, r); acct == nil {
		return
	}
	gateways := h.gateways
	if gateways == nil {
		gateways = []cnsa2.Gateway{}
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(struct {
		Gateways []cnsa2.Gateway `json:"gateways"`
	}{gateways})
}

// Enroll handles POST /v1/device/cnsa2/enroll.
func (h *CNSA2Handler) Enroll(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	acct := h.authAccount(w, r)
	if acct == nil {
		return
	}
	now := h.now()
	if acct.Tier == store.TierNone || now.After(acct.ActiveUntil) {
		http.Error(w, "no active subscription", http.StatusPaymentRequired)
		return
	}
	var req cnsa2EnrollReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2*cnsa2.MaxRequestBytes)).Decode(&req); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	der, err := base64.StdEncoding.DecodeString(req.Request)
	if err != nil {
		http.Error(w, "request must be base64", http.StatusBadRequest)
		return
	}
	keyHash, err := cnsa2.RequestKeyHash(der)
	if err != nil {
		http.Error(w, "certificate request not acceptable", http.StatusBadRequest)
		return
	}

	h.mu.Lock()
	defer h.mu.Unlock()

	dev, err := h.db.CNSA2DeviceByKeyHash(keyHash)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		log.Printf("cnsa2 device lookup: %v", err)
		http.Error(w, "server", http.StatusInternalServerError)
		return
	}
	if dev != nil {
		// Holding a public key is not proof of owning the device row. The
		// signing service still requires proof of the private key, but a key
		// never moves between accounts implicitly.
		if dev.AccountID != acct.ID {
			http.Error(w, "device ownership conflict", http.StatusConflict)
			return
		}
		n, err := h.db.CNSA2CertsIssuedSince(dev.UID, now.Add(-time.Hour))
		if err != nil {
			log.Printf("cnsa2 issue count: %v", err)
			http.Error(w, "server", http.StatusInternalServerError)
			return
		}
		if n >= cnsa2MaxIssuesPerHour {
			w.Header().Set("Retry-After", "3600")
			http.Error(w, "too many requests", http.StatusTooManyRequests)
			return
		}
	} else {
		uid, err := newCNSA2UID()
		if err != nil {
			http.Error(w, "server", http.StatusInternalServerError)
			return
		}
		dev = &store.CNSA2Device{AccountID: acct.ID, UID: uid, KeyHash: keyHash}
	}

	// Sign first, then make room and record. If signing fails nothing has
	// changed; no other device loses its slot for a request that went nowhere.
	issued, err := h.signer.IssueDevice(r.Context(), dev.UID+"."+h.nameSuffix, der)
	if errors.Is(err, cnsa2.ErrRejected) {
		http.Error(w, "certificate request not acceptable", http.StatusBadRequest)
		return
	}
	if err != nil {
		log.Printf("cnsa2 signing: %v", err)
		http.Error(w, "signing unavailable", http.StatusBadGateway)
		return
	}
	notAfter, _ := issued.Expiry()

	if dev.ID == 0 {
		// Same self-cleaning limit as WireGuard devices: a reinstall makes a
		// new key, so evict the least recently seen device rather than lock
		// the customer out. An evicted device's certificates are refused.
		existing, err := h.db.CNSA2DevicesForAccount(acct.ID)
		if err != nil {
			log.Printf("cnsa2 devices for account: %v", err)
			http.Error(w, "server", http.StatusInternalServerError)
			return
		}
		for acct.DeviceLimit > 0 && len(existing) >= acct.DeviceLimit {
			victim := 0
			for i := range existing {
				if existing[i].LastSeen.Before(existing[victim].LastSeen) {
					victim = i
				}
			}
			if err := h.db.RemoveCNSA2Device(existing[victim].ID, acct.ID, now); err != nil {
				log.Printf("cnsa2 evict device %d: %v", existing[victim].ID, err)
				http.Error(w, "server", http.StatusInternalServerError)
				return
			}
			log.Printf("cnsa2 device limit: evicted device %d (account %d)", existing[victim].ID, acct.ID)
			existing = append(existing[:victim], existing[victim+1:]...)
		}
	}
	if err := h.db.SaveCNSA2Enrollment(dev, issued.Serial, now, notAfter); err != nil {
		// The certificate exists but is unrecorded, so it could not be
		// revoked by device. It is never handed out.
		log.Printf("cnsa2 save enrollment (serial %s): %v", issued.Serial, err)
		http.Error(w, "server", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(cnsa2EnrollResp{
		Certificate: issued.Certificate, Issuing: issued.Issuing, Root: issued.Root,
		NotAfter: notAfter.UTC().Format(time.RFC3339),
		Device:   cnsa2DeviceInfo{ID: dev.ID, UID: dev.UID},
		Gateways: h.gateways,
	})
}

// Device handles DELETE /v1/device/cnsa2?id=<id>.
func (h *CNSA2Handler) Device(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	acct := h.authAccount(w, r)
	if acct == nil {
		return
	}
	id, err := strconv.ParseInt(r.URL.Query().Get("id"), 10, 64)
	if err != nil || id <= 0 {
		http.Error(w, "device id required", http.StatusBadRequest)
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	err = h.db.RemoveCNSA2Device(id, acct.ID, h.now())
	if errors.Is(err, store.ErrNotFound) {
		http.Error(w, "device not found", http.StatusNotFound)
		return
	}
	if err != nil {
		log.Printf("cnsa2 remove device: %v", err)
		http.Error(w, "server", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// DenyList handles GET /v1/internal/cnsa2/denylist: one certificate serial
// per line (lowercase hex, no leading zeros), ending with a line "# end <count>"
// so a gateway can tell a complete list from a cut-off one.
func (h *CNSA2Handler) DenyList(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !h.internalAuth(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	serials, err := h.db.CNSA2DeniedSerials(h.now())
	if err != nil {
		log.Printf("cnsa2 deny list: %v", err)
		http.Error(w, "server", http.StatusInternalServerError)
		return
	}
	var b strings.Builder
	for _, s := range serials {
		b.WriteString(s)
		b.WriteByte('\n')
	}
	b.WriteString("# end " + strconv.Itoa(len(serials)) + "\n")
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write([]byte(b.String()))
}

// newCNSA2UID returns a random device identifier that is also a valid DNS
// label: "d" followed by 32 hex characters.
func newCNSA2UID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return "d" + hex.EncodeToString(b[:]), nil
}
