package http

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/cloakvpn/api/internal/account"
	"github.com/cloakvpn/api/internal/store"
)

// The iOS app auto-recovers a rejected account number ONLY when the 401
// carries X-Lattice-Keeps-Previous-Numbers: 1 (see markNumberRecoverable).
// This pins the header to the "unknown account" 401 and checks that a
// number superseded by a store restore still authenticates.
func TestAccountUnknownNumberMarkedRecoverable(t *testing.T) {
	db, err := store.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer db.Close()
	const secret = "test-secret"
	h := NewAccountHandler(db, secret)

	get := func(number string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, "/v1/account", nil)
		req.Header.Set("Authorization", "Bearer "+number)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec
	}

	rec := get("00000-00000-00000-00000-00000")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("unknown number: status %d, want 401", rec.Code)
	}
	if got := rec.Header().Get("X-Lattice-Keeps-Previous-Numbers"); got != "1" {
		t.Errorf("unknown number: X-Lattice-Keeps-Previous-Numbers = %q, want 1", got)
	}

	// Phone holds the original number; a tablet then restores.
	phone, _ := account.Generate()
	tablet, _ := account.Generate()
	if _, err := db.CreateAccountApple(account.Hash(phone, secret), "txn-1",
		store.TierBasic, 3, time.Now().Add(24*time.Hour)); err != nil {
		t.Fatalf("create: %v", err)
	}
	if err := db.AddAccountNumberByAppleTxn("txn-1", account.Hash(tablet, secret)); err != nil {
		t.Fatalf("restore: %v", err)
	}
	for name, n := range map[string]string{"phone": phone, "tablet": tablet} {
		if rec := get(n); rec.Code != http.StatusOK {
			t.Errorf("%s number after restore: status %d, want 200 (body %q)", name, rec.Code, rec.Body.String())
		}
	}
}
