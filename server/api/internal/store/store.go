// Package store is a tiny SQLite wrapper that tracks accounts, their Stripe
// tier, and their provisioned devices. The DB lives on disk because we need it
// to survive reboots, BUT we store only what is strictly necessary for
// fulfilling a paid subscription:
//
//   - accounts(id, email, stripe_customer_id, tier, device_limit, active_until)
//   - devices(id, account_id, wg_pubkey, wg_ip, created_at)
//
// We do NOT store: IP addresses of paying customers, traffic logs, login
// timestamps, country/geo, or anything else that could unmask usage. Billing
// data on this box is kept off the network path — the wg concentrator reads
// only the wg_pubkey/wg_ip pair when a peer is added, and has no back-reference
// to the email or Stripe customer.
package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

type Tier string

const (
	TierNone  Tier = ""
	TierBasic Tier = "basic"
	TierPro   Tier = "pro"
)

type Account struct {
	ID               int64
	Email            string
	StripeCustomerID string
	Tier             Tier
	DeviceLimit      int
	ActiveUntil      time.Time
}

type Device struct {
	ID        int64
	AccountID int64
	WGPubkey  string
	WGIP      string
	CreatedAt time.Time
}

type DB struct{ *sql.DB }

func Open(path string) (*DB, error) {
	db, err := sql.Open("sqlite3", path+"?_journal_mode=WAL&_foreign_keys=on&_busy_timeout=5000")
	if err != nil {
		return nil, err
	}
	if err := db.Ping(); err != nil {
		return nil, err
	}
	if _, err := db.Exec(schema); err != nil {
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return &DB{db}, nil
}

const schema = `
CREATE TABLE IF NOT EXISTS accounts (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT,
  email              TEXT NOT NULL UNIQUE,
  stripe_customer_id TEXT,
  tier               TEXT NOT NULL DEFAULT '',
  device_limit       INTEGER NOT NULL DEFAULT 0,
  active_until       TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_accounts_stripe ON accounts(stripe_customer_id);

CREATE TABLE IF NOT EXISTS devices (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  wg_pubkey  TEXT NOT NULL UNIQUE,
  wg_ip      TEXT NOT NULL UNIQUE,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_devices_account ON devices(account_id);
`

// UpsertAccountByStripeCustomer creates or updates an account based on a
// Stripe customer ID + email, and sets the tier + limits + expiry.
func (d *DB) UpsertAccountByStripeCustomer(customerID, email string, tier Tier, limit int, activeUntil time.Time) (*Account, error) {
	if customerID == "" || email == "" {
		return nil, errors.New("customerID and email required")
	}
	_, err := d.Exec(`
		INSERT INTO accounts (email, stripe_customer_id, tier, device_limit, active_until)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(email) DO UPDATE SET
		  stripe_customer_id = excluded.stripe_customer_id,
		  tier               = excluded.tier,
		  device_limit       = excluded.device_limit,
		  active_until       = excluded.active_until
	`, email, customerID, tier, limit, activeUntil)
	if err != nil {
		return nil, err
	}
	return d.AccountByEmail(email)
}

// DeactivateByStripeCustomer clears the tier / device_limit when a subscription
// is canceled or goes unpaid. Existing device rows remain (so a customer who
// resubscribes can recover the same configs) but can no longer be used — the
// wg controller is expected to remove them.
func (d *DB) DeactivateByStripeCustomer(customerID string) error {
	_, err := d.Exec(`
		UPDATE accounts
		   SET tier = '', device_limit = 0, active_until = NULL
		 WHERE stripe_customer_id = ?
	`, customerID)
	return err
}

func (d *DB) AccountByEmail(email string) (*Account, error) {
	row := d.QueryRow(`
		SELECT id, email, COALESCE(stripe_customer_id, ''), tier, device_limit,
		       COALESCE(active_until, '1970-01-01T00:00:00Z')
		  FROM accounts WHERE email = ?`, email)
	var a Account
	var tier string
	var until time.Time
	if err := row.Scan(&a.ID, &a.Email, &a.StripeCustomerID, &tier, &a.DeviceLimit, &until); err != nil {
		return nil, err
	}
	a.Tier = Tier(tier)
	a.ActiveUntil = until
	return &a, nil
}

func (d *DB) DevicesForAccount(accountID int64) ([]Device, error) {
	rows, err := d.Query(`SELECT id, account_id, wg_pubkey, wg_ip, created_at
	                        FROM devices WHERE account_id = ? ORDER BY created_at`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Device
	for rows.Next() {
		var dv Device
		if err := rows.Scan(&dv.ID, &dv.AccountID, &dv.WGPubkey, &dv.WGIP, &dv.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, dv)
	}
	return out, rows.Err()
}

func (d *DB) AddDevice(accountID int64, pub, ip string) (*Device, error) {
	res, err := d.Exec(`INSERT INTO devices(account_id, wg_pubkey, wg_ip) VALUES (?, ?, ?)`,
		accountID, pub, ip)
	if err != nil {
		return nil, err
	}
	id, _ := res.LastInsertId()
	return &Device{ID: id, AccountID: accountID, WGPubkey: pub, WGIP: ip, CreatedAt: time.Now().UTC()}, nil
}

func (d *DB) DeleteDevice(id, accountID int64) error {
	_, err := d.Exec(`DELETE FROM devices WHERE id = ? AND account_id = ?`, id, accountID)
	return err
}
