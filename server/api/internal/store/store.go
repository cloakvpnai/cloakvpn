// Package store is a tiny SQLite wrapper that tracks accounts, their Stripe
// tier, and their provisioned devices. The DB lives on disk because we need it
// to survive reboots, BUT we store only what is strictly necessary for
// fulfilling a paid subscription — and, by design, NO personal data:
//
//   - accounts(id, account_number_hash, stripe_customer_id,
//     stripe_session_id, tier, device_limit, active_until)
//   - devices(id, account_id, region, wg_pubkey, wg_ip, created_at)
//
// There is no email, no name, no password. A subscription is identified only
// by a random account number, and this table holds only a keyed HMAC of that
// number (see package account) — a database leak yields no usable credentials.
// We also do NOT store: IP addresses of paying customers, traffic logs, login
// timestamps, country/geo. Billing identity lives in Stripe; the wg
// concentrator reads only the wg_pubkey/wg_ip pair when a peer is added.
//
// Multi-region: each device row carries the region it is currently
// provisioned in. A device has exactly one active region at a time — when a
// customer switches region in the app, the row's region + wg_ip are updated
// in place (see UpdateDeviceRegion). wg_ip is unique per region, since each
// concentrator runs its own 10.99.0.0/24; wg_pubkey is globally unique,
// because one physical device keeps one keypair regardless of region.
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

// ErrNotFound is returned by the AccountBy* / DeviceBy* lookups when no
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
	// AppleOriginalTxnID is the App Store originalTransactionId for accounts
	// minted from an in-app purchase (empty for Stripe-minted accounts). It
	// is the stable key for a subscription across renewals, so renewals and
	// cancellations from App Store Server Notifications map back to the row.
	AppleOriginalTxnID string
	// GooglePlayPurchaseToken is the Google Play purchase token for accounts
	// minted from a Play Billing subscription (empty otherwise). It is the
	// stable key Google's Developer API and Real-time Developer Notifications
	// use to identify the subscription. NOTE: Google issues a NEW purchase
	// token on an upgrade/downgrade or resignup; the new token's
	// linkedPurchaseToken points back to the old one, and we re-point the row
	// onto the new token (see RelinkGooglePlayToken) so the chain stays one row.
	GooglePlayPurchaseToken string
	Tier                    Tier
	DeviceLimit             int
	ActiveUntil             time.Time
}

type Device struct {
	ID        int64
	AccountID int64
	Region    string // region id the device is currently provisioned in
	WGPubkey  string
	WGIP      string
	CreatedAt time.Time
	LastSeen  time.Time // most recent provision/reconnect — drives limit eviction
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
	// Base schema first (no-op on an existing DB), then version migrations.
	if _, err := db.Exec(schema); err != nil {
		return nil, fmt.Errorf("schema: %w", err)
	}
	if err := migrate(db); err != nil {
		return nil, fmt.Errorf("migrate: %w", err)
	}
	if err := migrateDeviceLastSeen(db); err != nil {
		return nil, fmt.Errorf("migrate last_seen: %w", err)
	}
	if err := migrateAppleTxn(db); err != nil {
		return nil, fmt.Errorf("migrate apple_original_txn_id: %w", err)
	}
	if err := migrateGooglePlayToken(db); err != nil {
		return nil, fmt.Errorf("migrate google_play_purchase_token: %w", err)
	}
	return &DB{db}, nil
}

// migrateGooglePlayToken adds accounts.google_play_purchase_token (Migration
// 4): the Google Play purchase token for accounts minted from a Play Billing
// subscription, so renewals and cancellations from Real-time Developer
// Notifications can find the row. Idempotent — a no-op once the column exists.
func migrateGooglePlayToken(db *sql.DB) error {
	rows, err := db.Query(`PRAGMA table_info(accounts)`)
	if err != nil {
		return err
	}
	has := false
	for rows.Next() {
		var (
			cid         int
			name, ctype string
			notnull, pk int
			dflt        sql.NullString
		)
		if err := rows.Scan(&cid, &name, &ctype, &notnull, &dflt, &pk); err != nil {
			rows.Close()
			return err
		}
		if name == "google_play_purchase_token" {
			has = true
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	if has {
		return nil
	}
	if _, err := db.Exec(`ALTER TABLE accounts ADD COLUMN google_play_purchase_token TEXT`); err != nil {
		return fmt.Errorf("add column: %w", err)
	}
	if _, err := db.Exec(`CREATE INDEX IF NOT EXISTS idx_accounts_gplay_token ON accounts(google_play_purchase_token)`); err != nil {
		return fmt.Errorf("index: %w", err)
	}
	return nil
}

// migrateAppleTxn adds accounts.apple_original_txn_id (Migration 3): the App
// Store originalTransactionId for IAP-minted accounts, so renewals and
// cancellations from App Store Server Notifications can find the row.
// Idempotent — a no-op once the column exists.
func migrateAppleTxn(db *sql.DB) error {
	rows, err := db.Query(`PRAGMA table_info(accounts)`)
	if err != nil {
		return err
	}
	has := false
	for rows.Next() {
		var (
			cid         int
			name, ctype string
			notnull, pk int
			dflt        sql.NullString
		)
		if err := rows.Scan(&cid, &name, &ctype, &notnull, &dflt, &pk); err != nil {
			rows.Close()
			return err
		}
		if name == "apple_original_txn_id" {
			has = true
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	if has {
		return nil
	}
	if _, err := db.Exec(`ALTER TABLE accounts ADD COLUMN apple_original_txn_id TEXT`); err != nil {
		return fmt.Errorf("add column: %w", err)
	}
	if _, err := db.Exec(`CREATE INDEX IF NOT EXISTS idx_accounts_apple_txn ON accounts(apple_original_txn_id)`); err != nil {
		return fmt.Errorf("index: %w", err)
	}
	return nil
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
  region     TEXT NOT NULL DEFAULT '',
  wg_pubkey  TEXT NOT NULL UNIQUE,
  wg_ip      TEXT NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(region, wg_ip)
);
CREATE INDEX IF NOT EXISTS idx_devices_account ON devices(account_id);
`

// migrate brings an already-existing database forward to the current
// schema. It is idempotent: safe to run on every startup, a no-op once the
// DB is current. The base `schema` above only ever CREATEs missing tables —
// it can never alter a table that pre-dates a change — so structural changes
// to existing tables live here.
//
// Migration 1: the pre-multi-region `devices` table had no `region` column
// and a global UNIQUE on `wg_ip`. The new layout adds `region` and makes IP
// uniqueness per-region. SQLite cannot drop a column constraint in place, so
// the table is rebuilt: copy rows into a new table, swap names. Existing
// rows are pre-multi-region test data and get region=”.
func migrate(db *sql.DB) error {
	rows, err := db.Query(`PRAGMA table_info(devices)`)
	if err != nil {
		return err
	}
	hasRegion := false
	for rows.Next() {
		var (
			cid         int
			name, ctype string
			notnull, pk int
			dflt        sql.NullString
		)
		if err := rows.Scan(&cid, &name, &ctype, &notnull, &dflt, &pk); err != nil {
			rows.Close()
			return err
		}
		if name == "region" {
			hasRegion = true
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	if hasRegion {
		return nil // already on the multi-region schema
	}

	tx, err := db.Begin()
	if err != nil {
		return err
	}
	for _, stmt := range []string{
		`CREATE TABLE devices_new (
		   id         INTEGER PRIMARY KEY AUTOINCREMENT,
		   account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
		   region     TEXT NOT NULL DEFAULT '',
		   wg_pubkey  TEXT NOT NULL UNIQUE,
		   wg_ip      TEXT NOT NULL,
		   created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
		   UNIQUE(region, wg_ip)
		 )`,
		`INSERT INTO devices_new (id, account_id, region, wg_pubkey, wg_ip, created_at)
		   SELECT id, account_id, '', wg_pubkey, wg_ip, created_at FROM devices`,
		`DROP TABLE devices`,
		`ALTER TABLE devices_new RENAME TO devices`,
		`CREATE INDEX IF NOT EXISTS idx_devices_account ON devices(account_id)`,
	} {
		if _, err := tx.Exec(stmt); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("devices region migration: %w", err)
		}
	}
	return tx.Commit()
}

// migrateDeviceLastSeen adds devices.last_seen (Migration 2): the time of a
// device's most recent provision or reconnect. The self-cleaning device
// limit evicts the least-recently-seen device when a new one would exceed
// the tier cap, so a customer's reinstall reclaims a stale slot instead of
// being refused. Idempotent — a no-op once the column exists; existing rows
// are backfilled to created_at.
func migrateDeviceLastSeen(db *sql.DB) error {
	rows, err := db.Query(`PRAGMA table_info(devices)`)
	if err != nil {
		return err
	}
	has := false
	for rows.Next() {
		var (
			cid         int
			name, ctype string
			notnull, pk int
			dflt        sql.NullString
		)
		if err := rows.Scan(&cid, &name, &ctype, &notnull, &dflt, &pk); err != nil {
			rows.Close()
			return err
		}
		if name == "last_seen" {
			has = true
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	if has {
		return nil
	}
	// SQLite forbids CURRENT_TIMESTAMP as an ADD COLUMN default, so the
	// column is added nullable and backfilled from created_at; AddDevice and
	// TouchDevice set it explicitly thereafter.
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	for _, stmt := range []string{
		`ALTER TABLE devices ADD COLUMN last_seen TIMESTAMP`,
		`UPDATE devices SET last_seen = created_at WHERE last_seen IS NULL`,
	} {
		if _, err := tx.Exec(stmt); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("devices last_seen migration: %w", err)
		}
	}
	return tx.Commit()
}

// accountCols is the column list shared by every account lookup. COALESCE
// keeps the nullable columns scannable into non-pointer Go fields.
const accountCols = `id, account_number_hash, COALESCE(stripe_customer_id, ''), ` +
	`COALESCE(stripe_session_id, ''), tier, device_limit, ` +
	`COALESCE(active_until, '1970-01-01T00:00:00Z'), ` +
	`COALESCE(apple_original_txn_id, ''), ` +
	`COALESCE(google_play_purchase_token, '')`

func scanAccount(row *sql.Row) (*Account, error) {
	var a Account
	var tier string
	var until string
	err := row.Scan(&a.ID, &a.AccountNumberHash, &a.StripeCustomerID,
		&a.StripeSessionID, &tier, &a.DeviceLimit, &until, &a.AppleOriginalTxnID,
		&a.GooglePlayPurchaseToken)
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

// ---- Apple in-app-purchase accounts --------------------------------------

// AccountByAppleTxn looks up an account by its App Store originalTransactionId
// — used by the IAP verify endpoint (to extend an existing subscriber rather
// than mint a duplicate) and by App Store Server Notifications.
func (d *DB) AccountByAppleTxn(originalTxnID string) (*Account, error) {
	return scanAccount(d.QueryRow(
		`SELECT `+accountCols+` FROM accounts WHERE apple_original_txn_id = ?`, originalTxnID))
}

// CreateAccountApple mints a new account row for a first-time in-app purchase,
// keyed by the App Store originalTransactionId. Mirrors CreateAccount but for
// the Apple payment source (no Stripe customer/session).
func (d *DB) CreateAccountApple(numberHash, originalTxnID string,
	tier Tier, limit int, activeUntil time.Time) (*Account, error) {
	if numberHash == "" {
		return nil, errors.New("numberHash required")
	}
	if originalTxnID == "" {
		return nil, errors.New("originalTxnID required")
	}
	res, err := d.Exec(`
		INSERT INTO accounts
		  (account_number_hash, apple_original_txn_id, tier, device_limit, active_until)
		VALUES (?, ?, ?, ?, ?)`,
		numberHash, originalTxnID, tier, limit, formatTime(activeUntil))
	if err != nil {
		return nil, err
	}
	id, _ := res.LastInsertId()
	return &Account{
		ID:                 id,
		AccountNumberHash:  numberHash,
		AppleOriginalTxnID: originalTxnID,
		Tier:               tier,
		DeviceLimit:        limit,
		ActiveUntil:        activeUntil,
	}, nil
}

// UpdateSubscriptionByAppleTxn refreshes tier / limit / expiry on an App Store
// renewal or plan change (DID_RENEW / DID_CHANGE_RENEWAL_PREF notifications).
func (d *DB) UpdateSubscriptionByAppleTxn(originalTxnID string, tier Tier,
	limit int, activeUntil time.Time) error {
	_, err := d.Exec(`UPDATE accounts
	                     SET tier = ?, device_limit = ?, active_until = ?
	                   WHERE apple_original_txn_id = ?`,
		tier, limit, formatTime(activeUntil), originalTxnID)
	return err
}

// UpdateAccountHashByAppleTxn re-points an Apple-minted account at a new
// account-number hash. Used on a restore from a device with no local copy of
// the number: we re-mint and return a fresh number rather than store the
// plaintext server-side (the no-plaintext policy). The subscription identity
// (originalTransactionId) is unchanged.
func (d *DB) UpdateAccountHashByAppleTxn(originalTxnID, newHash string) error {
	_, err := d.Exec(`UPDATE accounts SET account_number_hash = ? WHERE apple_original_txn_id = ?`,
		newHash, originalTxnID)
	return err
}

// DeactivateByAppleTxn clears tier / limit / expiry when an App Store
// subscription expires, is refunded, or revoked (EXPIRED / REFUND / REVOKE).
func (d *DB) DeactivateByAppleTxn(originalTxnID string) error {
	_, err := d.Exec(`UPDATE accounts
	                     SET tier = '', device_limit = 0, active_until = NULL
	                   WHERE apple_original_txn_id = ?`, originalTxnID)
	return err
}

// ---- Google Play in-app-purchase accounts --------------------------------

// AccountByGooglePlayToken looks up an account by its Google Play purchase
// token — used by the Play verify endpoint (to extend an existing subscriber
// rather than mint a duplicate) and by Real-time Developer Notifications.
func (d *DB) AccountByGooglePlayToken(token string) (*Account, error) {
	return scanAccount(d.QueryRow(
		`SELECT `+accountCols+` FROM accounts WHERE google_play_purchase_token = ?`, token))
}

// CreateAccountGooglePlay mints a new account row for a first-time Play Billing
// purchase, keyed by the Google Play purchase token. Mirrors CreateAccount but
// for the Google payment source (no Stripe customer/session, no Apple txn).
func (d *DB) CreateAccountGooglePlay(numberHash, purchaseToken string,
	tier Tier, limit int, activeUntil time.Time) (*Account, error) {
	if numberHash == "" {
		return nil, errors.New("numberHash required")
	}
	if purchaseToken == "" {
		return nil, errors.New("purchaseToken required")
	}
	res, err := d.Exec(`
		INSERT INTO accounts
		  (account_number_hash, google_play_purchase_token, tier, device_limit, active_until)
		VALUES (?, ?, ?, ?, ?)`,
		numberHash, purchaseToken, tier, limit, formatTime(activeUntil))
	if err != nil {
		return nil, err
	}
	id, _ := res.LastInsertId()
	return &Account{
		ID:                      id,
		AccountNumberHash:       numberHash,
		GooglePlayPurchaseToken: purchaseToken,
		Tier:                    tier,
		DeviceLimit:             limit,
		ActiveUntil:             activeUntil,
	}, nil
}

// UpdateSubscriptionByGooglePlayToken refreshes tier / limit / expiry on a Play
// renewal or plan change (SUBSCRIPTION_RENEWED / _RECOVERED / _PURCHASED RTDNs).
func (d *DB) UpdateSubscriptionByGooglePlayToken(token string, tier Tier,
	limit int, activeUntil time.Time) error {
	_, err := d.Exec(`UPDATE accounts
	                     SET tier = ?, device_limit = ?, active_until = ?
	                   WHERE google_play_purchase_token = ?`,
		tier, limit, formatTime(activeUntil), token)
	return err
}

// RelinkGooglePlayToken re-points an account from an old purchase token to a
// new one. Google issues a fresh purchase token on an upgrade/downgrade or a
// resubscribe; the new purchase's linkedPurchaseToken names the old token. We
// move the row onto the new token so the subscription stays one account across
// the change. No-op rows-affected when oldToken is unknown.
func (d *DB) RelinkGooglePlayToken(oldToken, newToken string) error {
	_, err := d.Exec(`UPDATE accounts SET google_play_purchase_token = ? WHERE google_play_purchase_token = ?`,
		newToken, oldToken)
	return err
}

// UpdateAccountHashByGooglePlayToken re-points a Play-minted account at a new
// account-number hash. Used on a restore from a device with no local copy of
// the number: we re-mint and return a fresh number rather than store the
// plaintext server-side (the no-plaintext policy). The subscription identity
// (purchase token) is unchanged.
func (d *DB) UpdateAccountHashByGooglePlayToken(token, newHash string) error {
	_, err := d.Exec(`UPDATE accounts SET account_number_hash = ? WHERE google_play_purchase_token = ?`,
		newHash, token)
	return err
}

// DeactivateByGooglePlayToken clears tier / limit / expiry when a Play
// subscription expires, is revoked, or refunded (SUBSCRIPTION_EXPIRED /
// _REVOKED).
func (d *DB) DeactivateByGooglePlayToken(token string) error {
	_, err := d.Exec(`UPDATE accounts
	                     SET tier = '', device_limit = 0, active_until = NULL
	                   WHERE google_play_purchase_token = ?`, token)
	return err
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

// ---- devices -------------------------------------------------------------

// deviceCols is the column list shared by every device lookup, in the order
// scanDevice expects.
// last_seen is selected as a plain column, never COALESCE'd: the modernc
// SQLite driver only converts a result column to time.Time when the column
// carries a declared TIMESTAMP type, and a COALESCE() expression loses it
// (the same reason scanAccount reads active_until as a string). The Migration 2
// backfill leaves no NULL last_seen; scanDevice still falls back defensively.
const deviceCols = `id, account_id, region, wg_pubkey, wg_ip, created_at, last_seen`

// rowScanner is satisfied by both *sql.Row and *sql.Rows.
type rowScanner interface {
	Scan(dest ...any) error
}

func scanDevice(s rowScanner) (Device, error) {
	var dv Device
	var lastSeen sql.NullTime
	err := s.Scan(&dv.ID, &dv.AccountID, &dv.Region, &dv.WGPubkey, &dv.WGIP,
		&dv.CreatedAt, &lastSeen)
	// last_seen is backfilled by Migration 2 and set on every insert, so it
	// is never NULL in practice — fall back to created_at defensively.
	if lastSeen.Valid {
		dv.LastSeen = lastSeen.Time
	} else {
		dv.LastSeen = dv.CreatedAt
	}
	return dv, err
}

// DevicesForAccount returns every device row for an account, across all
// regions. A device has one row regardless of region, so len() of this is
// the count that the per-account device limit is enforced against.
func (d *DB) DevicesForAccount(accountID int64) ([]Device, error) {
	rows, err := d.Query(`SELECT `+deviceCols+`
	                        FROM devices WHERE account_id = ? ORDER BY created_at`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Device
	for rows.Next() {
		dv, err := scanDevice(rows)
		if err != nil {
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
	dv, err := scanDevice(d.QueryRow(
		`SELECT `+deviceCols+` FROM devices WHERE id = ? AND account_id = ?`, id, accountID))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &dv, nil
}

// DeviceByPubkey looks up a device by its WireGuard public key, which is
// globally unique (one physical device, one keypair, one row — even across
// region switches). POST /v1/device uses it to detect a re-provision or a
// region switch. Returns ErrNotFound when the device is new.
func (d *DB) DeviceByPubkey(pubkey string) (*Device, error) {
	dv, err := scanDevice(d.QueryRow(
		`SELECT `+deviceCols+` FROM devices WHERE wg_pubkey = ?`, pubkey))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &dv, nil
}

// DeviceIPsInRegion returns every allocated tunnel IP in one region. Each
// concentrator runs its own 10.99.0.0/24, so IP allocation only has to
// avoid collisions within the target region, not globally.
func (d *DB) DeviceIPsInRegion(region string) ([]string, error) {
	rows, err := d.Query(`SELECT wg_ip FROM devices WHERE region = ?`, region)
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

// AddDevice inserts a new device row in the given region. last_seen is set
// to now, so a freshly provisioned device is never the eviction victim.
func (d *DB) AddDevice(accountID int64, region, pub, ip string) (*Device, error) {
	res, err := d.Exec(
		`INSERT INTO devices(account_id, region, wg_pubkey, wg_ip, last_seen)
		 VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)`,
		accountID, region, pub, ip)
	if err != nil {
		return nil, err
	}
	id, _ := res.LastInsertId()
	now := time.Now().UTC()
	return &Device{
		ID:        id,
		AccountID: accountID,
		Region:    region,
		WGPubkey:  pub,
		WGIP:      ip,
		CreatedAt: now,
		LastSeen:  now,
	}, nil
}

// UpdateDeviceRegion moves an existing device to a new region, recording
// the freshly allocated tunnel IP there. Used when a customer switches
// region in the app — the caller has already revoked the old region's peer
// and provisioned the new one.
func (d *DB) UpdateDeviceRegion(deviceID int64, region, ip string) error {
	_, err := d.Exec(`UPDATE devices SET region = ?, wg_ip = ? WHERE id = ?`,
		region, ip, deviceID)
	return err
}

// TouchDevice records that a device just provisioned or reconnected. The
// self-cleaning device limit evicts the least-recently-seen device, so
// keeping this current ensures an actively-used device is never the victim.
func (d *DB) TouchDevice(id int64) error {
	_, err := d.Exec(`UPDATE devices SET last_seen = CURRENT_TIMESTAMP WHERE id = ?`, id)
	return err
}

func (d *DB) DeleteDevice(id, accountID int64) error {
	_, err := d.Exec(`DELETE FROM devices WHERE id = ? AND account_id = ?`, id, accountID)
	return err
}
