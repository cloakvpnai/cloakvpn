package http

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/cloakvpn/api/internal/account"
	"github.com/cloakvpn/api/internal/cnsa2"
	"github.com/cloakvpn/api/internal/store"
)

// fakeSigner stands in for the signing service. It never looks inside the
// request; the real one checks the request's signature.
type fakeSigner struct {
	n     int
	err   error
	names []string
}

func (f *fakeSigner) IssueDevice(_ context.Context, name string, _ []byte) (*cnsa2.Issued, error) {
	if f.err != nil {
		return nil, f.err
	}
	f.n++
	f.names = append(f.names, name)
	return &cnsa2.Issued{Certificate: "Y2VydA==", Issuing: "aXNz", Root: "cm9vdA==",
		Serial:   fmt.Sprintf("abc%d", f.n),
		NotAfter: time.Now().Add(30 * 24 * time.Hour).UTC().Format(time.RFC3339)}, nil
}

// testRequest builds a structurally valid PKCS#10 request around a random
// key of the given algorithm and size. The signature is junk on purpose.
func testRequest(t *testing.T, oid asn1.ObjectIdentifier, keyBytes int) string {
	t.Helper()
	type alg struct{ Algorithm asn1.ObjectIdentifier }
	type spki struct {
		Algorithm alg
		PublicKey asn1.BitString
	}
	type info struct {
		Version    int
		Subject    asn1.RawValue
		PublicKey  spki
		Attributes asn1.RawValue
	}
	type req struct {
		Info      info
		Algorithm alg
		Signature asn1.BitString
	}
	key := make([]byte, keyBytes)
	_, _ = rand.Read(key)
	der, err := asn1.Marshal(req{
		Info: info{
			Subject:    asn1.RawValue{FullBytes: []byte{0x30, 0x00}},
			PublicKey:  spki{alg{oid}, asn1.BitString{Bytes: key, BitLength: keyBytes * 8}},
			Attributes: asn1.RawValue{FullBytes: []byte{0xa0, 0x00}},
		},
		Algorithm: alg{oid},
		Signature: asn1.BitString{Bytes: []byte{1, 2, 3}, BitLength: 24},
	})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return base64.StdEncoding.EncodeToString(der)
}

func withTrailingByte(b64 string) string {
	der, _ := base64.StdEncoding.DecodeString(b64)
	return base64.StdEncoding.EncodeToString(append(der, 0))
}

var (
	oidMLDSA87 = asn1.ObjectIdentifier{2, 16, 840, 1, 101, 3, 4, 3, 19}
	oidMLDSA65 = asn1.ObjectIdentifier{2, 16, 840, 1, 101, 3, 4, 3, 18}
)

type cnsa2Fixture struct {
	t      *testing.T
	db     *store.DB
	h      *CNSA2Handler
	signer *fakeSigner
	now    time.Time
}

const (
	cnsa2TestSecret   = "test-secret"
	cnsa2TestInternal = "internal-secret"
)

func newCNSA2Fixture(t *testing.T) *cnsa2Fixture {
	db, err := store.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	f := &cnsa2Fixture{t: t, db: db, signer: &fakeSigner{}, now: time.Now()}
	f.h = NewCNSA2Handler(db, f.signer, cnsa2TestSecret, cnsa2TestInternal, "dev.example.",
		[]cnsa2.Gateway{{ID: "lab", Host: "198.51.100.7", Port: 1194, Name: "lab.gw.example"}})
	f.h.now = func() time.Time { return f.now }
	return f
}

func (f *cnsa2Fixture) account(txn string, limit int, until time.Time) string {
	num, _ := account.Generate()
	if _, err := f.db.CreateAccountApple(account.Hash(num, cnsa2TestSecret), txn, store.TierBasic, limit, until); err != nil {
		f.t.Fatalf("create account: %v", err)
	}
	return num
}

func (f *cnsa2Fixture) enroll(number, request string) (*httptest.ResponseRecorder, cnsa2EnrollResp) {
	body, _ := json.Marshal(cnsa2EnrollReq{Request: request})
	req := httptest.NewRequest(http.MethodPost, "/v1/device/cnsa2/enroll", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+number)
	rec := httptest.NewRecorder()
	f.h.Enroll(rec, req)
	var out cnsa2EnrollResp
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	return rec, out
}

func (f *cnsa2Fixture) denied() []string {
	req := httptest.NewRequest(http.MethodGet, "/v1/internal/cnsa2/denylist", nil)
	req.Header.Set("Authorization", "Bearer "+cnsa2TestInternal)
	rec := httptest.NewRecorder()
	f.h.DenyList(rec, req)
	if rec.Code != http.StatusOK {
		f.t.Fatalf("deny list: status %d", rec.Code)
	}
	lines := strings.Split(strings.TrimSpace(rec.Body.String()), "\n")
	last := lines[len(lines)-1]
	if last != fmt.Sprintf("# end %d", len(lines)-1) {
		f.t.Fatalf("deny list trailer %q for %d serials", last, len(lines)-1)
	}
	return lines[:len(lines)-1]
}

func TestCNSA2EnrollAndRenew(t *testing.T) {
	f := newCNSA2Fixture(t)
	num := f.account("txn-1", 3, f.now.Add(24*time.Hour))
	key := testRequest(t, oidMLDSA87, 2592)

	rec, first := f.enroll(num, key)
	if rec.Code != http.StatusOK {
		t.Fatalf("enroll: status %d (%s)", rec.Code, rec.Body.String())
	}
	if first.Certificate == "" || first.Root == "" || first.Issuing == "" || len(first.Gateways) != 1 {
		t.Fatalf("incomplete reply: %+v", first)
	}
	if !strings.HasPrefix(first.Device.UID, "d") || len(first.Device.UID) != 33 {
		t.Errorf("uid %q is not d + 32 hex", first.Device.UID)
	}
	if want := first.Device.UID + ".dev.example"; f.signer.names[0] != want {
		t.Errorf("certificate name %q, want %q", f.signer.names[0], want)
	}
	if strings.Contains(f.signer.names[0], num) {
		t.Error("certificate name contains the account number")
	}

	// Same key again is a renewal: same device, no new slot.
	rec, second := f.enroll(num, key)
	if rec.Code != http.StatusOK || second.Device != first.Device {
		t.Fatalf("renew: status %d device %+v, want %+v", rec.Code, second.Device, first.Device)
	}
	devs, _ := f.db.CNSA2DevicesForAccount(1)
	if len(devs) != 1 {
		t.Errorf("devices after renew = %d, want 1", len(devs))
	}
	if got := f.denied(); len(got) != 0 {
		t.Errorf("deny list after renew = %v, want empty", got)
	}
}

func TestCNSA2Refusals(t *testing.T) {
	f := newCNSA2Fixture(t)
	active := f.account("txn-1", 3, f.now.Add(24*time.Hour))
	lapsed := f.account("txn-2", 3, f.now.Add(-time.Hour))
	other := f.account("txn-3", 3, f.now.Add(24*time.Hour))
	key := testRequest(t, oidMLDSA87, 2592)

	cases := []struct {
		name, number, request string
		want                  int
	}{
		{"unknown account", "00000-00000-00000-00000-00000", key, http.StatusUnauthorized},
		{"no account number", "", key, http.StatusUnauthorized},
		{"lapsed subscription", lapsed, key, http.StatusPaymentRequired},
		{"not base64", active, "!!!", http.StatusBadRequest},
		{"not a request", active, base64.StdEncoding.EncodeToString([]byte("hello")), http.StatusBadRequest},
		{"empty", active, "", http.StatusBadRequest},
		{"ML-DSA-65 key", active, testRequest(t, oidMLDSA65, 1952), http.StatusBadRequest},
		{"ML-DSA-87 label, wrong size", active, testRequest(t, oidMLDSA87, 1952), http.StatusBadRequest},
		{"trailing bytes", active, withTrailingByte(key), http.StatusBadRequest},
	}
	for _, c := range cases {
		if rec, _ := f.enroll(c.number, c.request); rec.Code != c.want {
			t.Errorf("%s: status %d, want %d", c.name, rec.Code, c.want)
		}
	}
	if f.signer.n != 0 {
		t.Errorf("signing service was called %d times for refused requests", f.signer.n)
	}

	if rec, _ := f.enroll(active, key); rec.Code != http.StatusOK {
		t.Fatalf("enroll: %d", rec.Code)
	}
	// Another account presenting the same public key must not take the device.
	if rec, _ := f.enroll(other, key); rec.Code != http.StatusConflict {
		t.Errorf("same key, other account: status %d, want 409", rec.Code)
	}
}

func TestCNSA2SigningFailureChangesNothing(t *testing.T) {
	f := newCNSA2Fixture(t)
	num := f.account("txn-1", 1, f.now.Add(24*time.Hour))
	if rec, _ := f.enroll(num, testRequest(t, oidMLDSA87, 2592)); rec.Code != http.StatusOK {
		t.Fatalf("first enroll: %d", rec.Code)
	}

	f.signer.err = errors.New("kms down")
	if rec, _ := f.enroll(num, testRequest(t, oidMLDSA87, 2592)); rec.Code != http.StatusBadGateway {
		t.Errorf("signer down: status %d, want 502", rec.Code)
	}
	f.signer.err = cnsa2.ErrRejected
	if rec, _ := f.enroll(num, testRequest(t, oidMLDSA87, 2592)); rec.Code != http.StatusBadRequest {
		t.Errorf("signer rejected: status %d, want 400", rec.Code)
	}
	// The account is at its limit of 1. A failed enrollment must not have
	// evicted the working device.
	devs, _ := f.db.CNSA2DevicesForAccount(1)
	if len(devs) != 1 {
		t.Errorf("devices = %d, want the original 1", len(devs))
	}
	if got := f.denied(); len(got) != 0 {
		t.Errorf("deny list = %v, want empty", got)
	}
}

func TestCNSA2LimitEvictsAndDenies(t *testing.T) {
	f := newCNSA2Fixture(t)
	num := f.account("txn-1", 2, f.now.Add(24*time.Hour))
	for i := 0; i < 2; i++ {
		if rec, _ := f.enroll(num, testRequest(t, oidMLDSA87, 2592)); rec.Code != http.StatusOK {
			t.Fatalf("enroll %d: %d", i, rec.Code)
		}
	}
	// Make the first device the stale one.
	if _, err := f.db.Exec(`UPDATE cnsa2_devices SET last_seen = '2020-01-01 00:00:00' WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	if rec, _ := f.enroll(num, testRequest(t, oidMLDSA87, 2592)); rec.Code != http.StatusOK {
		t.Fatalf("third enroll: %d", rec.Code)
	}
	devs, _ := f.db.CNSA2DevicesForAccount(1)
	if len(devs) != 2 || devs[0].ID != 2 || devs[1].ID != 3 {
		t.Fatalf("devices after eviction = %+v, want ids 2 and 3", devs)
	}
	if got := f.denied(); len(got) != 1 || got[0] != "abc1" {
		t.Errorf("deny list = %v, want the evicted device's serial abc1", got)
	}
}

func TestCNSA2RemoveDevice(t *testing.T) {
	f := newCNSA2Fixture(t)
	num := f.account("txn-1", 3, f.now.Add(24*time.Hour))
	other := f.account("txn-2", 3, f.now.Add(24*time.Hour))
	key := testRequest(t, oidMLDSA87, 2592)
	_, first := f.enroll(num, key)
	f.enroll(num, key) // a renewal: the device now has two live certificates

	del := func(number, id string) int {
		req := httptest.NewRequest(http.MethodDelete, "/v1/device/cnsa2?id="+id, nil)
		req.Header.Set("Authorization", "Bearer "+number)
		rec := httptest.NewRecorder()
		f.h.Device(rec, req)
		return rec.Code
	}
	id := fmt.Sprint(first.Device.ID)
	if got := del(other, id); got != http.StatusNotFound {
		t.Errorf("other account deleting: status %d, want 404", got)
	}
	if got := del(num, "x"); got != http.StatusBadRequest {
		t.Errorf("bad id: status %d, want 400", got)
	}
	if got := del(num, id); got != http.StatusNoContent {
		t.Fatalf("delete: status %d, want 204", got)
	}
	if got := f.denied(); len(got) != 2 {
		t.Errorf("deny list = %v, want both certificates of the removed device", got)
	}
	// The same key may enroll again afterwards, as a new device.
	rec, again := f.enroll(num, key)
	if rec.Code != http.StatusOK || again.Device.UID == first.Device.UID {
		t.Errorf("re-enroll after removal: status %d uid reused=%v", rec.Code, again.Device.UID == first.Device.UID)
	}
	// Once the certificates have expired there is nothing left to deny.
	f.now = f.now.Add(31 * 24 * time.Hour)
	if got := f.denied(); len(got) != 0 {
		t.Errorf("deny list after expiry = %v, want empty", got)
	}
}

func TestCNSA2RenewalRateLimit(t *testing.T) {
	f := newCNSA2Fixture(t)
	num := f.account("txn-1", 3, f.now.Add(24*time.Hour))
	key := testRequest(t, oidMLDSA87, 2592)
	for i := 0; i < cnsa2MaxIssuesPerHour; i++ {
		if rec, _ := f.enroll(num, key); rec.Code != http.StatusOK {
			t.Fatalf("enroll %d: %d", i, rec.Code)
		}
	}
	if rec, _ := f.enroll(num, key); rec.Code != http.StatusTooManyRequests {
		t.Errorf("over the hourly limit: status %d, want 429", rec.Code)
	}
	f.now = f.now.Add(61 * time.Minute)
	if rec, _ := f.enroll(num, key); rec.Code != http.StatusOK {
		t.Errorf("an hour later: status %d, want 200", rec.Code)
	}
}

func TestCNSA2DenyListNeedsInternalSecret(t *testing.T) {
	f := newCNSA2Fixture(t)
	num := f.account("txn-1", 3, f.now.Add(24*time.Hour))
	for _, auth := range []string{"", "Bearer wrong", "Bearer " + num, cnsa2TestInternal} {
		req := httptest.NewRequest(http.MethodGet, "/v1/internal/cnsa2/denylist", nil)
		if auth != "" {
			req.Header.Set("Authorization", auth)
		}
		rec := httptest.NewRecorder()
		f.h.DenyList(rec, req)
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("auth %q: status %d, want 401", auth, rec.Code)
		}
	}
}

func TestCNSA2LapsedSubscriptionIsDenied(t *testing.T) {
	f := newCNSA2Fixture(t)
	until := f.now.Add(24 * time.Hour)
	paying := f.account("txn-lapse", 3, until)
	other := f.account("txn-stays", 3, f.now.Add(60*24*time.Hour))
	rec, lapsing := f.enroll(paying, testRequest(t, oidMLDSA87, 2592))
	if rec.Code != http.StatusOK {
		t.Fatalf("enroll: %d %s", rec.Code, rec.Body)
	}
	if rec, _ := f.enroll(other, testRequest(t, oidMLDSA87, 2592)); rec.Code != http.StatusOK {
		t.Fatalf("enroll other: %d", rec.Code)
	}
	if got := f.denied(); len(got) != 0 {
		t.Fatalf("while paid: denied %v", got)
	}

	// Inside the grace period nothing changes.
	f.now = until.Add(store.CNSA2LapseGrace - time.Minute)
	if got := f.denied(); len(got) != 0 {
		t.Fatalf("inside grace: denied %v", got)
	}

	// Past it, that account's certificate is refused and the other account's is not.
	f.now = until.Add(store.CNSA2LapseGrace + time.Minute)
	got := f.denied()
	if len(got) != 1 {
		t.Fatalf("after lapse: denied %v, want exactly the lapsed account's certificate", got)
	}
	_ = lapsing

	// Renewing the subscription takes it off the list again.
	if err := f.db.UpdateSubscriptionByAppleTxn("txn-lapse", store.TierBasic, 3, f.now.Add(30*24*time.Hour)); err != nil {
		t.Fatalf("renew: %v", err)
	}
	if got := f.denied(); len(got) != 0 {
		t.Fatalf("after renewal: denied %v", got)
	}
}
