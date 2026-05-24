// Package account generates and verifies Lattice VPN account numbers —
// the no-account credential model (see docs/BILLING_INTEGRATION.md).
//
// A subscription is identified solely by a random account number. The
// server never stores the number itself, only a keyed HMAC of it, so a
// database leak yields no usable credentials. The plaintext is shown to
// the customer once on the website and otherwise lives only in the
// Stripe customer's metadata (for recovery).
package account

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"
)

// MetadataKey is the Stripe customer-metadata field the plaintext
// account number is stored under, so it can be recovered later.
const MetadataKey = "lattice_account_number"

// crockford is the Crockford base-32 alphabet — excludes I, L, O and U
// to avoid visual ambiguity when a customer reads/types the number.
const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// numberLen is the count of symbols in an account number. 25 symbols ×
// 5 bits/symbol ≈ 125 bits of entropy — far beyond brute-force range.
const numberLen = 25

// groupSize is the display grouping: 25 symbols shown as five groups of
// five, e.g. "8Q2K4-MN7PR-...". Hyphens are cosmetic (see Normalize).
const groupSize = 5

// Generate returns a fresh random account number, formatted for display
// in hyphen-separated groups. Each symbol is drawn uniformly from the
// 32-symbol alphabet (256 mod 32 == 0, so byte%32 has no modulo bias).
func Generate() (string, error) {
	buf := make([]byte, numberLen)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("account number rand: %w", err)
	}
	var sb strings.Builder
	for i, b := range buf {
		if i > 0 && i%groupSize == 0 {
			sb.WriteByte('-')
		}
		sb.WriteByte(crockford[int(b)%32])
	}
	return sb.String(), nil
}

// Normalize strips display formatting — hyphens, whitespace, and case —
// so a number entered with or without the grouping hashes identically.
func Normalize(number string) string {
	var sb strings.Builder
	for _, r := range strings.ToUpper(number) {
		switch r {
		case '-', ' ', '\t', '\n', '\r':
			// drop cosmetic formatting
		default:
			sb.WriteRune(r)
		}
	}
	return sb.String()
}

// Hash returns the lowercase-hex HMAC-SHA256 of the normalized account
// number under secret. Only this value is persisted server-side.
func Hash(number, secret string) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(Normalize(number)))
	return hex.EncodeToString(mac.Sum(nil))
}
