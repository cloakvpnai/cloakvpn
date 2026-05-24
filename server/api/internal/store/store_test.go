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
