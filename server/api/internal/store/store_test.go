package store

import (
	"path/filepath"
	"testing"
	"time"
)

// TestAccountTimeRoundTrip is a regression test for the bug where an
// account's active_until was stored as a raw Go time.Time. The modernc
// SQLite driver serialized it with a monotonic-clock suffix
// ("… +0000 UTC m=+3024061…"), which then failed to parse on read — so
// every lookup of an existing account returned a 500. CreateAccount must
// store a normalized RFC3339 string and scanAccount must read it back.
func TestAccountTimeRoundTrip(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer db.Close()

	// time.Now() carries a monotonic-clock reading — exactly the value
	// shape that triggered the original bug.
	want := time.Now().Add(35 * 24 * time.Hour)
	created, err := db.CreateAccount("hash-abc", "cus_TEST", "cs_test_xyz",
		TierBasic, 3, want)
	if err != nil {
		t.Fatalf("CreateAccount: %v", err)
	}

	// Look the account back up by every key the API uses.
	for _, tc := range []struct {
		name   string
		lookup func() (*Account, error)
	}{
		{"by session", func() (*Account, error) { return db.AccountBySession("cs_test_xyz") }},
		{"by number hash", func() (*Account, error) { return db.AccountByNumberHash("hash-abc") }},
		{"by stripe customer", func() (*Account, error) { return db.AccountByStripeCustomer("cus_TEST") }},
	} {
		got, err := tc.lookup()
		if err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		if got.ID != created.ID {
			t.Errorf("%s: id = %d, want %d", tc.name, got.ID, created.ID)
		}
		if got.Tier != TierBasic || got.DeviceLimit != 3 {
			t.Errorf("%s: tier/limit = %s/%d, want basic/3", tc.name, got.Tier, got.DeviceLimit)
		}
		if got.StripeCustomerID != "cus_TEST" {
			t.Errorf("%s: customer = %q, want cus_TEST", tc.name, got.StripeCustomerID)
		}
		// active_until must round-trip to within a second of the input.
		if d := got.ActiveUntil.Sub(want); d > time.Second || d < -time.Second {
			t.Errorf("%s: active_until = %v, want ~%v (drift %v)",
				tc.name, got.ActiveUntil, want, d)
		}
	}
}

// TestSubscriptionUpdateAndDeactivate covers the other two writers of
// active_until: a renewal (UpdateSubscription…) and a cancellation
// (Deactivate…, which sets the column NULL).
func TestSubscriptionUpdateAndDeactivate(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer db.Close()

	if _, err := db.CreateAccount("h", "cus_X", "cs_X", TierBasic, 3,
		time.Now().Add(24*time.Hour)); err != nil {
		t.Fatalf("CreateAccount: %v", err)
	}

	renewal := time.Now().Add(365 * 24 * time.Hour)
	if err := db.UpdateSubscriptionByStripeCustomer("cus_X", TierPro, 6, renewal); err != nil {
		t.Fatalf("UpdateSubscription: %v", err)
	}
	got, err := db.AccountByStripeCustomer("cus_X")
	if err != nil {
		t.Fatalf("lookup after update: %v", err)
	}
	if got.Tier != TierPro || got.DeviceLimit != 6 {
		t.Errorf("after update: tier/limit = %s/%d, want pro/6", got.Tier, got.DeviceLimit)
	}
	if d := got.ActiveUntil.Sub(renewal); d > time.Second || d < -time.Second {
		t.Errorf("after update: active_until drift %v", d)
	}

	// Deactivate sets active_until = NULL; the COALESCE default must still
	// parse cleanly rather than erroring the whole lookup.
	if err := db.DeactivateByStripeCustomer("cus_X"); err != nil {
		t.Fatalf("Deactivate: %v", err)
	}
	got, err = db.AccountByStripeCustomer("cus_X")
	if err != nil {
		t.Fatalf("lookup after deactivate: %v", err)
	}
	if got.Tier != TierNone || got.DeviceLimit != 0 {
		t.Errorf("after deactivate: tier/limit = %s/%d, want none/0", got.Tier, got.DeviceLimit)
	}
}

// TestRestoreKeepsOtherDevicesSignedIn is the regression test for the
// 2026-10-07 incident: Restore Purchases on an iPad re-minted the Apple
// account's number and REPLACED the only stored hash, so the customer's
// iPhone got "account number wasn't recognized" (HTTP 401) on every region.
// A restore must add a number, not invalidate the ones other devices hold.
func TestRestoreKeepsOtherDevicesSignedIn(t *testing.T) {
	for _, tc := range []struct {
		name   string
		create func(db *DB, hash string) (*Account, error)
		add    func(db *DB, hash string) error
	}{
		{
			"apple",
			func(db *DB, h string) (*Account, error) {
				return db.CreateAccountApple(h, "txn-1", TierBasic, 3, time.Now().Add(24*time.Hour))
			},
			func(db *DB, h string) error { return db.AddAccountNumberByAppleTxn("txn-1", h) },
		},
		{
			"google",
			func(db *DB, h string) (*Account, error) {
				return db.CreateAccountGooglePlay(h, "tok-1", TierBasic, 3, time.Now().Add(24*time.Hour))
			},
			func(db *DB, h string) error { return db.AddAccountNumberByGooglePlayToken("tok-1", h) },
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			db, err := Open(filepath.Join(t.TempDir(), "test.db"))
			if err != nil {
				t.Fatalf("Open: %v", err)
			}
			defer db.Close()

			acct, err := tc.create(db, "phone-number")
			if err != nil {
				t.Fatalf("create: %v", err)
			}
			if err := tc.add(db, "tablet-number"); err != nil {
				t.Fatalf("add: %v", err)
			}
			for _, h := range []string{"phone-number", "tablet-number"} {
				got, err := db.AccountByNumberHash(h)
				if err != nil {
					t.Fatalf("%s should still authenticate: %v", h, err)
				}
				if got.ID != acct.ID {
					t.Errorf("%s: account %d, want %d", h, got.ID, acct.ID)
				}
			}
			// The newest number becomes the account's current one.
			got, _ := db.AccountByNumberHash("phone-number")
			if got.AccountNumberHash != "tablet-number" {
				t.Errorf("current hash = %q, want tablet-number", got.AccountNumberHash)
			}
			// Unknown numbers are still rejected.
			if _, err := db.AccountByNumberHash("never-issued"); err != ErrNotFound {
				t.Errorf("unknown number: err = %v, want ErrNotFound", err)
			}
		})
	}
}

// TestRestoreCapsLiveNumbers checks the oldest numbers age out once a
// subscription exceeds its live-number cap, so repeated restores cannot
// accumulate unbounded credentials.
func TestRestoreCapsLiveNumbers(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer db.Close()

	// Basic plan: device_limit 3 → 3 live numbers.
	if _, err := db.CreateAccountApple("n0", "txn-cap", TierBasic, 3,
		time.Now().Add(24*time.Hour)); err != nil {
		t.Fatalf("create: %v", err)
	}
	for _, h := range []string{"n1", "n2", "n3", "n4"} {
		if err := db.AddAccountNumberByAppleTxn("txn-cap", h); err != nil {
			t.Fatalf("add %s: %v", h, err)
		}
	}
	for _, h := range []string{"n0", "n1"} {
		if _, err := db.AccountByNumberHash(h); err != ErrNotFound {
			t.Errorf("%s should have aged out: err = %v", h, err)
		}
	}
	for _, h := range []string{"n2", "n3", "n4"} {
		if _, err := db.AccountByNumberHash(h); err != nil {
			t.Errorf("%s should be live: %v", h, err)
		}
	}

	// Re-adding the current number is a no-op, not a duplicate.
	if err := db.AddAccountNumberByAppleTxn("txn-cap", "n4"); err != nil {
		t.Fatalf("idempotent add: %v", err)
	}
	if _, err := db.AccountByNumberHash("n2"); err != nil {
		t.Errorf("idempotent add must not prune: %v", err)
	}

	// Unknown subscription → ErrNotFound, nothing written.
	if err := db.AddAccountNumberByAppleTxn("no-such-txn", "x"); err != ErrNotFound {
		t.Errorf("unknown txn: err = %v, want ErrNotFound", err)
	}
}

func TestLiveNumberCap(t *testing.T) {
	for limit, want := range map[int]int{0: 3, 1: 3, 3: 3, 6: 6, 10: 10, 50: 10} {
		if got := liveNumberCap(limit); got != want {
			t.Errorf("liveNumberCap(%d) = %d, want %d", limit, got, want)
		}
	}
}

// TestAliasTableOnExistingDB opens a DB twice: the second Open must not fail
// on the already-created alias table (the schema runs on every startup).
func TestAliasTableOnExistingDB(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.db")
	for i := 0; i < 2; i++ {
		db, err := Open(path)
		if err != nil {
			t.Fatalf("Open #%d: %v", i+1, err)
		}
		db.Close()
	}
}
