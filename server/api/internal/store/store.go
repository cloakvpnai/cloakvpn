// Package store is a tiny SQLite wrapper that tracks accounts, their Stripe
// tier, and their provisioned devices. The DB lives on disk because we need it
// to survive reboots, BUT we store only what is strictly necessary for
// fulfilling a paid subscription — and, by design, NO personal data:
//
//   - accounts(id, account_number_hash, stripe_customer_id,
//     stripe_session_id, tier, device_limit, active_until)
//   - devices(id, account_id, wg_pubkey, wg_ip, created_at)
//
// There is no email, no name, no password. A subscription is identified only
// by a random account number, and this table holds only a keyed HMAC of that
// number (see package account) — a database leak yields no usable credentials.
// We also do NOT store: IP addresses of paying customers, traffic logs, login
// timestamps, country/geo. Billing identity lives in Stripe; the wg
// concentrator reads only the wg_pubkey/wg_ip pair when a peer is added.
package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	// modernc.org/sqlite is a pure-Go SQLite (transpiled from C). No CGO
	// required, so the API can be cross-compiled cleanly from the Mac and
	// scp'd to the concentrator. The driver registers itself as "sqlite"
	// (no trailing "3"), so update sql.Open below if you swap it back.
	_ "modernc.org/sqlite"
)

// ErrNotFound is returned by the AccountBy* / DeviceByID lookups when no
// matching row exists, so callers can map it to a 404 / 401.
var ErrNotFound = errors.New("not found")

type Tier string

const (
	TierNone  Tier = ""
	TierBasic Tier = "basic"
	TierPro   Tier = "pro"
)

type Account struct {
	ID                int64
	AccountNumberHash string
	StripeCustomerID  string
	StripeSessionID   string
	Tier              Tier
	DeviceLimit       int
	ActiveUntil       time.Time
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
	// modernc.org/sqlite uses driver name "sqlite" (not "sqlite3"). Pragmas
	// are set via separate PRAGMA statements rather than DSN query params,
	// since the modernc DSN syntax differs from go-sqlite3.
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	if err := db.Ping(); err != nil {
		return nil, err
	}
	for _, p := range []string{
		"PRAGMA journal_mode=WAL",
		"PRAGMA foreign_keys=ON",
		"PRAGMA busy_timeout=5000",
	} {
		if _, err := db.Exec(p); err != nil {
			return nil, fmt.Errorf("%s: %w", p, err)
		}
	}
	if _, err := db.Exec(schema); err != nil {
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return &DB{db}, nil
}

const schema = `
CREATE TABLE IF NOT EXISTS accounts (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  account_number_hash TEXT NOT NULL UNIQUE,
  stripe_customer_id  TEXT,
  stripe_session_id   TEXT,
  tier                TEXT NOT NULL DEFAULT '',
  device_limit        INTEGER NOT NULL DEFAULT 0,
  active_until        TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_accounts_stripe  ON accounts(stripe_customer_id);
CREATE INDEX IF NOT EXISTS idx_accounts_session ON accounts(stripe_session_id);

CREATE TABLE IF NOT EXISTS devices (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  wg_pubkey  TEXT NOT NULL UNIQUE,
  wg_ip      TEXT NOT NULL UNIQUE,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_devices_account ON devices(account_id);
`

// accountCols is the column list shared by every account lookup. COALESCE
// keeps the nullable columns scannable into non-pointer Go fields.
const accountCols = `id, account_number_hash, COALESCE(stripe_customer_id, ''), ` +
	`COALESCE(stripe_session_id, ''), tier, device_limit, ` +
	`COALESCE(active_until, '1970-01-01T00:00:00Z')`

func scanAccount(row *sql.Row) (*Account, error) {
	var a Account
	var tier string
	var until string
	err := row.Scan(&a.ID, &a.AccountNumberHash, &a.StripeCustomerID,
		&a.StripeSessionID, &tier, &a.DeviceLimit, &until)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	a.Tier = Tier(tier)
	// active_until is stored as a normalized RFC3339 string (see
	// CreateAccount). The modernc SQLite driver does not round-trip a Go
	// time.Time directly — it serializes one with a monotonic-clock suffix
	// that cannot be parsed back — so we control the format on both sides.
	t, err := time.Parse(time.RFC3339Nano, until)
	if err != nil {
		return nil, fmt.Errorf("parse active_until %q: %w", until, err)
	}
	a.ActiveUntil = t
	return &a, nil
}

// formatTime renders a time.Time for storage: UTC (which drops the
// monotonic-clock reading) in RFC3339 with nanoseconds.
func formatTime(t time.Time) string {
	return t.UTC().Format(time.RFC3339Nano)
}

// CreateAccount inserts a new account keyed by the HMAC of its account
// number. Called by the Stripe webhook when a checkout completes.
func (d *DB) CreateAccount(numberHash, stripeCustomerID, stripeSessionID string,
	tier Tier, limit int, activeUntil time.Time) (*Account, error) {
	if numberHash == "" {
		return nil, errors.New("numberHash required")
	}
	res, err := d.Exec(`
		INSERT INTO accounts
		  (account_number_hash, stripe_customer_id, stripe_session_id,
		   tier, device_limit, active_until)
		VALUES (?, ?, ?, ?, ?, ?)`,
		numberHash, stripeCustomerID, stripeSessionID, tier, limit, formatTime(activeUntil))
	if err != nil {
		return nil, err
	}
	id, _ := res.LastInsertId()
	return &Account{
		ID:                id,
		AccountNumberHash: numberHash,
		StripeCustomerID:  stripeCustomerID,
		StripeSessionID:   stripeSessionID,
		Tier:              tier,
		DeviceLimit:       limit,
		ActiveUntil:       activeUntil,
	}, nil
}

// AccountByNumberHash looks up an account by the HMAC of the account
// number presented by the app. Returns ErrNotFound if there is no match.
func (d *DB) AccountByNumberHash(hash string) (*Account, error) {
	return scanAccount(d.QueryRow(
		`SELECT `+accountCols+` FROM accounts WHERE account_number_hash = ?`, hash))
}

// AccountByStripeCustomer looks up an account by Stripe customer ID —
// used by the webhook to apply renewals and cancellations.
func (d *DB) AccountByStripeCustomer(customerID string) (*Account, error) {
	return scanAccount(d.QueryRow(
		`SELECT `+accountCols+` FROM accounts WHERE stripe_customer_id = ?`, customerID))
}

// AccountBySession looks up an account by the Stripe checkout session ID
// — used by GET /v1/account-number for the website welcome page.
func (d *DB) AccountBySession(sessionID string) (*Account, error) {
	return scanAccount(d.QueryRow(
		`SELECT `+accountCols+` FROM accounts WHERE stripe_session_id = ?`, sessionID))
}

// UpdateSubscriptionByStripeCustomer refreshes tier / limit / expiry on a
// renewal or plan change.
func (d *DB) UpdateSubscriptionByStripeCustomer(customerID string, tier Tier,
	limit int, activeUntil time.Time) error {
	_, err := d.Exec(`UPDATE accounts
	                     SET tier = ?, device_limit = ?, active_until = ?
	                   WHERE stripe_customer_id = ?`,
		tier, limit, formatTime(activeUntil), customerID)
	return err
}

// DeactivateByStripeCustomer clears the tier / device_limit when a
// subscription is canceled or goes unpaid. Existing device rows remain
// (so a customer who resubscribes can recover the same configs) but can
// no longer be used — the wg controller is expected to remove them.
func (d *DB) DeactivateByStripeCustomer(customerID string) error {
	_, err := d.Exec(`UPDATE accounts
	                     SET tier = '', device_limit = 0, active_until = NULL
	                   WHERE stripe_customer_id = ?`, customerID)
	return err
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

// DeviceByID fetches a single device, scoped to its owning account so one
// account can never revoke another's device. Returns ErrNotFound if there
// is no such device for that account.
func (d *DB) DeviceByID(id, accountID int64) (*Device, error) {
	var dv Device
	err := d.QueryRow(`SELECT id, account_id, wg_pubkey, wg_ip, created_at
	                     FROM devices WHERE id = ? AND account_id = ?`, id, accountID).
		Scan(&dv.ID, &dv.AccountID, &dv.WGPubkey, &dv.WGIP, &dv.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &dv, nil
}

// DeviceByPubkey looks up a device by its WireGuard public key, which is
// globally unique. POST /v1/device uses it to detect a re-provision: the
// app keeps a stable keypair, so a reconnect (or a reinstall that kept
// app data, or the same phone moving to a new account number) presents
// the same wg_pubkey. Returns ErrNotFound when the device is new.
func (d *DB) DeviceByPubkey(pubkey string) (*Device, error) {
	var dv Device
	err := d.QueryRow(`SELECT id, account_id, wg_pubkey, wg_ip, created_at
	                     FROM devices WHERE wg_pubkey = ?`, pubkey).
		Scan(&dv.ID, &dv.AccountID, &dv.WGPubkey, &dv.WGIP, &dv.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &dv, nil
}

// AllDeviceIPs returns every allocated tunnel IP across ALL accounts.
// wg_ip is globally unique — every peer on wg0 needs a distinct address —
// so IP allocation for a new device must avoid the whole set, not just
// the requesting account's own devices.
func (d *DB) AllDeviceIPs() ([]string, error) {
	rows, err := d.Query(`SELECT wg_ip FROM devices`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ips []string
	for rows.Next() {
		var ip string
		if err := rows.Scan(&ip); err != nil {
			return nil, err
		}
		ips = append(ips, ip)
	}
	return ips, rows.Err()
}

// ReassignDevice moves a device row to a different account — used when the
// same physical device (same wg_pubkey) signs in under a new account
// number on the same phone.
func (d *DB) ReassignDevice(deviceID, newAccountID int64) error {
	_, err := d.Exec(`UPDATE devices SET account_id = ? WHERE id = ?`,
		newAccountID, deviceID)
	return err
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
