package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// CNSA 2.0 mode keeps its own device rows. A device there is identified by
// its ML-DSA-87 public key (key_hash) and is given an opaque uid, which is
// the only name that appears in its certificate.
//
// cnsa2_certs outlives the device row on purpose: when a device is removed
// its unexpired certificate serials are what the gateways must refuse.
const cnsa2Schema = `
CREATE TABLE IF NOT EXISTS cnsa2_devices (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  uid        TEXT NOT NULL UNIQUE,
  key_hash   TEXT NOT NULL UNIQUE,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_cnsa2_devices_account ON cnsa2_devices(account_id);
CREATE TABLE IF NOT EXISTS cnsa2_certs (
  serial     TEXT PRIMARY KEY,
  device_uid TEXT NOT NULL,
  account_id INTEGER NOT NULL,
  issued_at  TEXT NOT NULL,
  not_after  TEXT NOT NULL,
  revoked_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_cnsa2_certs_device ON cnsa2_certs(device_uid);
`

// cnsa2Time is fixed-width UTC to the second, so stored values compare
// correctly as text.
func cnsa2Time(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05Z") }

func migrateCNSA2(db *sql.DB) error {
	_, err := db.Exec(cnsa2Schema)
	return err
}

type CNSA2Device struct {
	ID        int64
	AccountID int64
	UID       string
	KeyHash   string
	CreatedAt time.Time
	LastSeen  time.Time
}

const cnsa2DeviceCols = `id, account_id, uid, key_hash, created_at, last_seen`

func scanCNSA2Device(s rowScanner) (CNSA2Device, error) {
	var d CNSA2Device
	err := s.Scan(&d.ID, &d.AccountID, &d.UID, &d.KeyHash, &d.CreatedAt, &d.LastSeen)
	return d, err
}

func (d *DB) CNSA2DeviceByKeyHash(keyHash string) (*CNSA2Device, error) {
	dev, err := scanCNSA2Device(d.QueryRow(
		`SELECT `+cnsa2DeviceCols+` FROM cnsa2_devices WHERE key_hash = ?`, keyHash))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &dev, nil
}

func (d *DB) CNSA2DeviceByID(id, accountID int64) (*CNSA2Device, error) {
	dev, err := scanCNSA2Device(d.QueryRow(
		`SELECT `+cnsa2DeviceCols+` FROM cnsa2_devices WHERE id = ? AND account_id = ?`, id, accountID))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &dev, nil
}

func (d *DB) CNSA2DevicesForAccount(accountID int64) ([]CNSA2Device, error) {
	rows, err := d.Query(
		`SELECT `+cnsa2DeviceCols+` FROM cnsa2_devices WHERE account_id = ? ORDER BY id`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []CNSA2Device
	for rows.Next() {
		dev, err := scanCNSA2Device(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, dev)
	}
	return out, rows.Err()
}

// SaveCNSA2Enrollment records a freshly issued certificate and, for a new
// device, the device row, in one transaction. dev.ID == 0 means new.
func (d *DB) SaveCNSA2Enrollment(dev *CNSA2Device, serial string, issuedAt, notAfter time.Time) error {
	tx, err := d.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if dev.ID == 0 {
		res, err := tx.Exec(
			`INSERT INTO cnsa2_devices(account_id, uid, key_hash) VALUES (?, ?, ?)`,
			dev.AccountID, dev.UID, dev.KeyHash)
		if err != nil {
			return err
		}
		dev.ID, _ = res.LastInsertId()
		dev.CreatedAt, dev.LastSeen = issuedAt, issuedAt
	} else {
		if _, err := tx.Exec(
			`UPDATE cnsa2_devices SET last_seen = CURRENT_TIMESTAMP WHERE id = ?`, dev.ID); err != nil {
			return err
		}
		dev.LastSeen = issuedAt
	}
	if _, err := tx.Exec(
		`INSERT INTO cnsa2_certs(serial, device_uid, account_id, issued_at, not_after) VALUES (?, ?, ?, ?, ?)`,
		serial, dev.UID, dev.AccountID, cnsa2Time(issuedAt), cnsa2Time(notAfter)); err != nil {
		return err
	}
	return tx.Commit()
}

// RemoveCNSA2Device deletes the device and marks every certificate issued to
// it as revoked, so the gateways refuse them until they expire.
func (d *DB) RemoveCNSA2Device(id, accountID int64, now time.Time) error {
	tx, err := d.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var uid string
	err = tx.QueryRow(`SELECT uid FROM cnsa2_devices WHERE id = ? AND account_id = ?`, id, accountID).Scan(&uid)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if _, err := tx.Exec(
		`UPDATE cnsa2_certs SET revoked_at = ? WHERE device_uid = ? AND revoked_at IS NULL`,
		cnsa2Time(now), uid); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM cnsa2_devices WHERE id = ?`, id); err != nil {
		return err
	}
	return tx.Commit()
}

// CNSA2CertsIssuedSince counts certificates issued to one device since a time.
func (d *DB) CNSA2CertsIssuedSince(uid string, since time.Time) (int, error) {
	var n int
	err := d.QueryRow(
		`SELECT COUNT(*) FROM cnsa2_certs WHERE device_uid = ? AND issued_at >= ?`,
		uid, cnsa2Time(since)).Scan(&n)
	return n, err
}

// CNSA2LapseGrace is how long after a subscription ends its certificates stay
// usable. It absorbs a renewal notice from the payment provider arriving a
// little late; it is not a free period.
const CNSA2LapseGrace = time.Hour

// CNSA2DeniedSerials returns the serials of unexpired certificates the
// gateways must refuse: revoked ones, and every certificate of an account
// whose subscription has ended (or that no longer exists). A lapsed account
// comes off the list by itself when it renews. An expired certificate is
// refused by every gateway anyway, so the list stays as short as the
// certificate lifetime allows.
func (d *DB) CNSA2DeniedSerials(now time.Time) ([]string, error) {
	rows, err := d.Query(
		`SELECT c.serial, c.revoked_at IS NOT NULL, a.id IS NOT NULL,
		        COALESCE(a.tier, ''), COALESCE(a.active_until, '1970-01-01T00:00:00Z')
		   FROM cnsa2_certs c LEFT JOIN accounts a ON a.id = c.account_id
		  WHERE c.not_after > ? ORDER BY c.serial`,
		cnsa2Time(now))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var serial, tier, until string
		var revoked, hasAccount bool
		if err := rows.Scan(&serial, &revoked, &hasAccount, &tier, &until); err != nil {
			return nil, err
		}
		denied := revoked || !hasAccount || Tier(tier) == TierNone
		if !denied {
			activeUntil, err := time.Parse(time.RFC3339Nano, until)
			if err != nil {
				return nil, fmt.Errorf("parse active_until %q: %w", until, err)
			}
			denied = now.After(activeUntil.Add(CNSA2LapseGrace))
		}
		if denied {
			out = append(out, serial)
		}
	}
	return out, rows.Err()
}
