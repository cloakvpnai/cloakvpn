// Package cnsa2 holds the pieces of CNSA 2.0 device enrollment that are not
// HTTP or storage: reading a device's certificate request, and the client for
// the signing service.
//
// The API never signs anything and holds no certificate authority key. It
// decides WHO may enroll; the signing service decides what a certificate says
// and has the key in AWS KMS do the signing.
package cnsa2

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/asn1"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// OID of ML-DSA-87 (FIPS 204), the only device key type accepted.
var oidMLDSA87 = asn1.ObjectIdentifier{2, 16, 840, 1, 101, 3, 4, 3, 19}

const mldsa87PublicKeyBytes = 2592

// MaxRequestBytes bounds a PKCS#10 request: a 2,592 byte key plus a 4,627
// byte signature and a short subject is under 7.5 KB.
const MaxRequestBytes = 12000

type algorithm struct {
	Algorithm  asn1.ObjectIdentifier
	Parameters asn1.RawValue `asn1:"optional"`
}

type publicKeyInfo struct {
	Raw       asn1.RawContent
	Algorithm algorithm
	PublicKey asn1.BitString
}

type requestInfo struct {
	Raw        asn1.RawContent
	Version    int
	Subject    asn1.RawValue
	PublicKey  publicKeyInfo
	Attributes asn1.RawValue `asn1:"tag:0,optional"`
}

type request struct {
	Info      requestInfo
	Algorithm algorithm
	Signature asn1.BitString
}

// ErrBadRequest means the certificate request is malformed or carries a key
// that is not ML-DSA-87.
var ErrBadRequest = errors.New("certificate request not acceptable")

// RequestKeyHash returns a stable identifier for the public key inside a
// PKCS#10 request: the hex SHA-256 of its SubjectPublicKeyInfo. It does not
// check the request's signature; the signing service does that before it
// signs anything.
func requestKey(der []byte) ([]byte, error) {
	if len(der) == 0 || len(der) > MaxRequestBytes {
		return nil, ErrBadRequest
	}
	var req request
	rest, err := asn1.Unmarshal(der, &req)
	if err != nil || len(rest) != 0 {
		return nil, ErrBadRequest
	}
	pk := req.Info.PublicKey
	if req.Info.Version != 0 || !pk.Algorithm.Algorithm.Equal(oidMLDSA87) ||
		len(pk.Algorithm.Parameters.FullBytes) != 0 ||
		pk.PublicKey.BitLength != mldsa87PublicKeyBytes*8 {
		return nil, ErrBadRequest
	}
	return pk.Raw, nil
}

// RequestKeyHash returns the SHA-384 of the public key in a certificate
// request, in hex. It identifies a device or gateway key.
func RequestKeyHash(der []byte) (string, error) {
	raw, err := requestKey(der)
	if err != nil {
		return "", err
	}
	sum := sha512.Sum384(raw)
	return hex.EncodeToString(sum[:]), nil
}

// LegacyRequestKeyHash is the SHA-256 form stored before Nov 24, 2026. It is
// used only to find an existing device row so it can be moved to SHA-384.
func LegacyRequestKeyHash(der []byte) (string, error) {
	raw, err := requestKey(der)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:]), nil
}

// Issued is what the signing service returns. Certificates are base64 DER.
type Issued struct {
	Certificate string `json:"certificate"`
	Issuing     string `json:"issuing"`
	Root        string `json:"root"`
	Serial      string `json:"serial"`
	NotAfter    string `json:"notAfter"`
}

// Expiry parses NotAfter.
func (i Issued) Expiry() (time.Time, error) { return time.Parse(time.RFC3339, i.NotAfter) }

// Signer issues a certificate for a request. Implemented by Client; tests
// substitute their own.
type Signer interface {
	IssueDevice(ctx context.Context, name string, requestDER []byte) (*Issued, error)
	IssueGateway(ctx context.Context, name string, requestDER []byte) (*Issued, error)
}

// ErrRejected means the signing service refused the request itself (bad
// signature, wrong key type). Anything else is an outage on our side.
var ErrRejected = errors.New("signing service rejected the request")

// Client talks to the signing service.
type Client struct {
	url   string
	token string
	http  *http.Client
}

func NewClient(url, token string) *Client {
	return &Client{url: strings.TrimRight(url, "/"), token: token, http: &http.Client{Timeout: 20 * time.Second}}
}

func (c *Client) IssueDevice(ctx context.Context, name string, requestDER []byte) (*Issued, error) {
	return c.issue(ctx, "device", name, requestDER)
}

// IssueGateway asks for a server certificate (90 days) for a gateway name.
func (c *Client) IssueGateway(ctx context.Context, name string, requestDER []byte) (*Issued, error) {
	return c.issue(ctx, "gateway", name, requestDER)
}

func (c *Client) issue(ctx context.Context, kind, name string, requestDER []byte) (*Issued, error) {
	body, _ := json.Marshal(map[string]string{
		"kind": kind, "name": name, "request": base64.StdEncoding.EncodeToString(requestDER),
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.url+"/v1/issue", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+c.token)
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode == http.StatusBadRequest {
		return nil, ErrRejected
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("signing service: status %d", resp.StatusCode)
	}
	var out Issued
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, fmt.Errorf("signing service: %w", err)
	}
	if out.Certificate == "" || out.Serial == "" {
		return nil, errors.New("signing service: incomplete reply")
	}
	if _, err := out.Expiry(); err != nil {
		return nil, fmt.Errorf("signing service: bad expiry: %w", err)
	}
	return &out, nil
}

// Gateway is one CNSA 2.0 gateway the apps may connect to. Name is the DNS
// name in the gateway's certificate, which the app checks.
//
// KeyHash is the SHA-384 of the gateway's public key (the same value
// RequestKeyHash gives for its certificate request). It is configuration
// for certificate renewal only and is never sent to apps.
//
// TCPHost and TCPPort are the gateway's second way in, for networks that
// block UDP: an IPv4 address (not a name, since apps cannot look names up
// while they hold traffic) and a port, normally 443, where the same tunnel is
// accepted over TCP. Both are left out for a gateway that has no TCP
// listener. Apps that do not know these fields ignore them.
type Gateway struct {
	ID      string `json:"id"`
	Host    string `json:"host"`
	Port    int    `json:"port"`
	Name    string `json:"name"`
	TCPHost string `json:"tcp_host,omitempty"`
	TCPPort int    `json:"tcp_port,omitempty"`
	KeyHash string `json:"key_sha384,omitempty"`
}
