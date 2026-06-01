// Package appleiap verifies App Store in-app-purchase artifacts (StoreKit 2
// signed transactions and App Store Server Notifications V2) and reconciles
// them with the account-number system.
//
// All trust flows from Apple's signatures: every artifact Apple hands us is a
// JWS (JSON Web Signature, ES256) whose header carries the full x5c
// certificate chain (leaf → Apple WWDR intermediate → Apple Root CA - G3).
// We verify the chain terminates at the embedded Apple Root CA - G3 and that
// the leaf actually signed the payload, then — and only then — trust the
// claims inside. No App Store Server API key is required for this path.
package appleiap

import (
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/x509"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"time"
)

//go:embed AppleRootCA-G3.pem
var appleRootPEM []byte

// appleRoots is the trust anchor pool (Apple Root CA - G3), parsed once.
var appleRoots *x509.CertPool

func init() {
	appleRoots = x509.NewCertPool()
	if !appleRoots.AppendCertsFromPEM(appleRootPEM) {
		panic("appleiap: failed to parse embedded Apple Root CA - G3")
	}
}

// JWSTransaction is the subset of a StoreKit 2 signed transaction payload we
// act on. Field names match Apple's JWSTransactionDecodedPayload.
type JWSTransaction struct {
	TransactionID         string `json:"transactionId"`
	OriginalTransactionID string `json:"originalTransactionId"`
	BundleID              string `json:"bundleId"`
	ProductID             string `json:"productId"`
	Type                  string `json:"type"` // "Auto-Renewable Subscription"
	// Milliseconds since epoch.
	PurchaseDate     int64  `json:"purchaseDate"`
	ExpiresDate      int64  `json:"expiresDate"`
	RevocationDate   int64  `json:"revocationDate"`
	Environment      string `json:"environment"` // "Sandbox" | "Production"
}

// ExpiresAt converts the millisecond expiry to a time.Time (zero if unset).
func (t JWSTransaction) ExpiresAt() time.Time {
	if t.ExpiresDate == 0 {
		return time.Time{}
	}
	return time.UnixMilli(t.ExpiresDate).UTC()
}

// Revoked reports whether the transaction carries a revocation date (refund
// or family-sharing revoke).
func (t JWSTransaction) Revoked() bool { return t.RevocationDate > 0 }

// NotificationPayload is the subset of an App Store Server Notification V2
// decoded payload we act on.
type NotificationPayload struct {
	NotificationType string `json:"notificationType"`
	Subtype          string `json:"subtype"`
	Data             struct {
		BundleID              string `json:"bundleId"`
		Environment           string `json:"environment"`
		SignedTransactionInfo string `json:"signedTransactionInfo"`
		SignedRenewalInfo     string `json:"signedRenewalInfo"`
	} `json:"data"`
}

// jwsHeader is the protected header of a JWS we care about.
type jwsHeader struct {
	Alg string   `json:"alg"`
	X5C []string `json:"x5c"`
}

var (
	errMalformedJWS = errors.New("appleiap: malformed JWS")
	errUnsupported  = errors.New("appleiap: unsupported JWS alg (want ES256)")
)

// VerifyTransaction verifies a StoreKit 2 signed-transaction JWS and returns
// its decoded payload, or an error if the signature/chain is invalid.
func VerifyTransaction(signedJWS string) (*JWSTransaction, error) {
	raw, err := verifyJWS(signedJWS)
	if err != nil {
		return nil, err
	}
	var tx JWSTransaction
	if err := json.Unmarshal(raw, &tx); err != nil {
		return nil, fmt.Errorf("appleiap: decode transaction: %w", err)
	}
	return &tx, nil
}

// VerifyNotification verifies the outer notification JWS and the inner
// signedTransactionInfo, returning the notification payload and the decoded
// transaction it refers to.
func VerifyNotification(signedPayload string) (*NotificationPayload, *JWSTransaction, error) {
	raw, err := verifyJWS(signedPayload)
	if err != nil {
		return nil, nil, err
	}
	var n NotificationPayload
	if err := json.Unmarshal(raw, &n); err != nil {
		return nil, nil, fmt.Errorf("appleiap: decode notification: %w", err)
	}
	if n.Data.SignedTransactionInfo == "" {
		return &n, nil, nil // some notification types carry no transaction
	}
	tx, err := VerifyTransaction(n.Data.SignedTransactionInfo)
	if err != nil {
		return nil, nil, fmt.Errorf("appleiap: inner transaction: %w", err)
	}
	return &n, tx, nil
}

// verifyJWS validates an Apple ES256 JWS: it checks the x5c chain terminates
// at Apple Root CA - G3 and that the leaf certificate's key signed
// "<header>.<payload>", then returns the decoded payload bytes.
func verifyJWS(token string) ([]byte, error) {
	h, p, sig, signingInput, err := splitJWS(token)
	if err != nil {
		return nil, err
	}
	if h.Alg != "ES256" {
		return nil, errUnsupported
	}
	if len(h.X5C) == 0 {
		return nil, fmt.Errorf("%w: empty x5c", errMalformedJWS)
	}

	// Parse the x5c chain (base64 STD, DER certs): [0]=leaf, [1..]=intermediates.
	var leaf *x509.Certificate
	intermediates := x509.NewCertPool()
	for i, b64 := range h.X5C {
		der, err := base64.StdEncoding.DecodeString(b64)
		if err != nil {
			return nil, fmt.Errorf("%w: x5c[%d] base64: %v", errMalformedJWS, i, err)
		}
		cert, err := x509.ParseCertificate(der)
		if err != nil {
			return nil, fmt.Errorf("%w: x5c[%d] parse: %v", errMalformedJWS, i, err)
		}
		if i == 0 {
			leaf = cert
		} else {
			intermediates.AddCert(cert)
		}
	}

	// Chain must terminate at Apple Root CA - G3.
	if _, err := leaf.Verify(x509.VerifyOptions{
		Roots:         appleRoots,
		Intermediates: intermediates,
		// Apple's leaf certs are code-signing-style; don't constrain EKU.
		KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
	}); err != nil {
		return nil, fmt.Errorf("appleiap: x5c chain not trusted: %w", err)
	}

	// Verify the ES256 signature over the signing input with the leaf key.
	pub, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok {
		return nil, fmt.Errorf("appleiap: leaf key is not ECDSA")
	}
	if len(sig) != 64 {
		return nil, fmt.Errorf("%w: ES256 signature must be 64 bytes, got %d", errMalformedJWS, len(sig))
	}
	r := new(big.Int).SetBytes(sig[:32])
	s := new(big.Int).SetBytes(sig[32:])
	digest := sha256.Sum256(signingInput)
	if !ecdsa.Verify(pub, digest[:], r, s) {
		return nil, fmt.Errorf("appleiap: signature verification failed")
	}

	return p, nil
}

// splitJWS decodes a compact JWS into its header struct, raw payload bytes,
// raw signature bytes, and the exact "<header>.<payload>" signing input.
func splitJWS(token string) (jwsHeader, []byte, []byte, []byte, error) {
	var h jwsHeader
	// A compact JWS is base64url(header).base64url(payload).base64url(sig).
	dot1 := indexByte(token, '.')
	if dot1 < 0 {
		return h, nil, nil, nil, errMalformedJWS
	}
	dot2 := indexByte(token[dot1+1:], '.')
	if dot2 < 0 {
		return h, nil, nil, nil, errMalformedJWS
	}
	dot2 += dot1 + 1

	hSeg, pSeg, sSeg := token[:dot1], token[dot1+1:dot2], token[dot2+1:]

	hRaw, err := base64.RawURLEncoding.DecodeString(hSeg)
	if err != nil {
		return h, nil, nil, nil, fmt.Errorf("%w: header b64: %v", errMalformedJWS, err)
	}
	if err := json.Unmarshal(hRaw, &h); err != nil {
		return h, nil, nil, nil, fmt.Errorf("%w: header json: %v", errMalformedJWS, err)
	}
	pRaw, err := base64.RawURLEncoding.DecodeString(pSeg)
	if err != nil {
		return h, nil, nil, nil, fmt.Errorf("%w: payload b64: %v", errMalformedJWS, err)
	}
	sRaw, err := base64.RawURLEncoding.DecodeString(sSeg)
	if err != nil {
		return h, nil, nil, nil, fmt.Errorf("%w: sig b64: %v", errMalformedJWS, err)
	}
	signingInput := []byte(hSeg + "." + pSeg)
	return h, pRaw, sRaw, signingInput, nil
}

func indexByte(s string, b byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == b {
			return i
		}
	}
	return -1
}
