package http

import (
	"fmt"
	"github.com/cloakvpn/api/internal/account"
	"github.com/cloakvpn/api/internal/regions"
	"github.com/cloakvpn/api/internal/store"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestDeviceProvisionOwnership(t *testing.T) {
	for _, tc := range []struct {
		name   string
		other  bool
		region string
		status int
		calls  int32
	}{{"cross_account_same_region", true, "one", 409, 0}, {"cross_account_other_region", true, "two", 409, 0}, {"same_account_reprovision", false, "one", 200, 1}, {"same_account_region_change", false, "two", 200, 2}} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			db, e := store.Open(filepath.Join(dir, "test.db"))
			if e != nil {
				t.Fatal(e)
			}
			defer db.Close()
			const secret = "test-secret"
			owner, _ := account.Generate()
			other, _ := account.Generate()
			a, e := db.CreateAccountApple(account.Hash(owner, secret), "owner", store.TierBasic, 3, time.Now().Add(time.Hour))
			if e != nil {
				t.Fatal(e)
			}
			_, e = db.CreateAccountApple(account.Hash(other, secret), "other", store.TierBasic, 3, time.Now().Add(time.Hour))
			if e != nil {
				t.Fatal(e)
			}
			device, e := db.AddDevice(a.ID, "one", "fixture-wg-public", "10.99.0.2")
			if e != nil {
				t.Fatal(e)
			}
			device, e = db.DeviceByPubkey("fixture-wg-public")
			if e != nil {
				t.Fatal(e)
			}
			var calls atomic.Int32
			region := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				w.Header().Set("Content-Type", "application/json")
				fmt.Fprint(w, `{}`)
			}))
			defer region.Close()
			file := filepath.Join(dir, "regions.json")
			os.WriteFile(file, []byte(fmt.Sprintf(`[{"id":"one","url":%q},{"id":"two","url":%q}]`, region.URL, region.URL)), 0600)
			regs, e := regions.Load(file)
			if e != nil {
				t.Fatal(e)
			}
			h := NewDeviceHandler(db, regs, regions.NewClient("local-test"), secret, "one", "10.99.0.0/24")
			number := owner
			if tc.other {
				number = other
			}
			r := httptest.NewRequest(http.MethodPost, "/v1/device", strings.NewReader(fmt.Sprintf(`{"wg_pubkey":"fixture-wg-public","rosenpass_pubkey":"fixture-rp-public","region":%q}`, tc.region)))
			r.Header.Set("Authorization", "Bearer "+number)
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != tc.status {
				t.Fatalf("status=%d expected=%d", w.Code, tc.status)
			}
			if !tc.other && tc.region == "two" {
				// Existing production code intentionally delays old-region revoke 8s.
				deadline := time.Now().Add(10 * time.Second)
				for calls.Load() < 2 && time.Now().Before(deadline) {
					time.Sleep(20 * time.Millisecond)
				}
			}
			if calls.Load() != tc.calls {
				t.Fatalf("region side effects=%d expected=%d", calls.Load(), tc.calls)
			}
			got, e := db.DeviceByPubkey("fixture-wg-public")
			if e != nil {
				t.Fatal(e)
			}
			expectedRegion := "one"
			if !tc.other {
				expectedRegion = tc.region
			}
			if got.ID != device.ID || got.AccountID != a.ID || got.Region != expectedRegion || (expectedRegion == "one" && got.WGIP != device.WGIP) {
				t.Fatal("existing device identity/owner/location changed")
			}
			if tc.other && !got.LastSeen.Equal(device.LastSeen) {
				t.Fatal("rejected request touched device")
			}
		})
	}
}
