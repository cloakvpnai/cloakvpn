// Package googleplay verifies Google Play Billing subscription purchases and
// reconciles them with the account-number system.
//
// Unlike Apple's StoreKit 2 transactions — which are self-contained signed
// JWS artifacts we can verify offline — a Google Play purchase token is opaque
// and carries no signed claims. The authoritative state of a subscription
// (its product, expiry, and lifecycle state) lives behind the Google Play
// Developer API. So all trust here flows from a server-to-server call: we
// authenticate to Google with a service-account JWT, exchange it for an OAuth2
// access token, and GET purchases.subscriptionsv2 for the purchase token. The
// response Google returns is the source of truth.
//
// To keep the module's dependency surface small (it otherwise only pulls in
// modernc sqlite + stripe-go), this implements the service-account JWT-bearer
// OAuth2 flow and the REST calls with the standard library rather than
// google.golang.org/api.
package googleplay

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

const (
	androidPublisherScope = "https://www.googleapis.com/auth/androidpublisher"
	apiBase               = "https://androidpublisher.googleapis.com/androidpublisher/v3"
)

// serviceAccount is the subset of a Google Cloud service-account JSON key file
// we need to mint an OAuth2 access token.
type serviceAccount struct {
	Type        string `json:"type"`
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
	TokenURI    string `json:"token_uri"`
}

// Client calls the Google Play Developer API on behalf of a single app
// (PackageName), authenticating with a service account. It is safe for
// concurrent use; the OAuth2 access token is cached and refreshed under a mutex.
type Client struct {
	pkg   string
	sa    serviceAccount
	key   *rsa.PrivateKey
	httpc *http.Client

	mu       sync.Mutex
	token    string
	tokenExp time.Time
}

// NewClient parses a service-account JSON key and returns a Developer API
// client for packageName. Returns an error if the key is malformed.
func NewClient(packageName string, serviceAccountJSON []byte) (*Client, error) {
	var sa serviceAccount
	if err := json.Unmarshal(serviceAccountJSON, &sa); err != nil {
		return nil, fmt.Errorf("googleplay: parse service account: %w", err)
	}
	if sa.ClientEmail == "" || sa.PrivateKey == "" {
		return nil, fmt.Errorf("googleplay: service account missing client_email/private_key")
	}
	if sa.TokenURI == "" {
		sa.TokenURI = "https://oauth2.googleapis.com/token"
	}
	key, err := parseRSAPrivateKey(sa.PrivateKey)
	if err != nil {
		return nil, fmt.Errorf("googleplay: parse private key: %w", err)
	}
	return &Client{
		pkg:   packageName,
		sa:    sa,
		key:   key,
		httpc: &http.Client{Timeout: 15 * time.Second},
	}, nil
}

// parseRSAPrivateKey decodes a PEM-encoded PKCS#8 (or PKCS#1) RSA key, as
// emitted in the service-account JSON's private_key field.
func parseRSAPrivateKey(pemStr string) (*rsa.PrivateKey, error) {
	block, _ := pem.Decode([]byte(pemStr))
	if block == nil {
		return nil, fmt.Errorf("no PEM block")
	}
	if k, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		rsaKey, ok := k.(*rsa.PrivateKey)
		if !ok {
			return nil, fmt.Errorf("not an RSA key")
		}
		return rsaKey, nil
	}
	// Fall back to PKCS#1.
	return x509.ParsePKCS1PrivateKey(block.Bytes)
}

// SubscriptionState mirrors the relevant values of SubscriptionPurchaseV2's
// subscriptionState enum.
type SubscriptionState string

const (
	StateActive      SubscriptionState = "SUBSCRIPTION_STATE_ACTIVE"
	StateInGracePer  SubscriptionState = "SUBSCRIPTION_STATE_IN_GRACE_PERIOD"
	StateOnHold      SubscriptionState = "SUBSCRIPTION_STATE_ON_HOLD"
	StatePaused      SubscriptionState = "SUBSCRIPTION_STATE_PAUSED"
	StateCanceled    SubscriptionState = "SUBSCRIPTION_STATE_CANCELED"
	StateExpired     SubscriptionState = "SUBSCRIPTION_STATE_EXPIRED"
	StatePending     SubscriptionState = "SUBSCRIPTION_STATE_PENDING"
	StateUnspecified SubscriptionState = "SUBSCRIPTION_STATE_UNSPECIFIED"
)

// Subscription is the decoded, app-relevant view of a Google Play
// subscription purchase.
type Subscription struct {
	State SubscriptionState
	// ProductID is the subscription product (the Play Console subscription ID).
	// For a multi-line-item purchase we take the first line item.
	ProductID string
	// Expiry is the latest expiry across line items.
	Expiry time.Time
	// LatestOrderID is Google's order identifier for the most recent charge.
	LatestOrderID string
	// LinkedPurchaseToken, when present, names the purchase token this one
	// replaced (an upgrade/downgrade or resubscribe). We use it to re-point
	// an existing account row onto the new token.
	LinkedPurchaseToken string
	// Acknowledged is true once the purchase has been acknowledged. Google
	// auto-refunds purchases that are not acknowledged within three days.
	Acknowledged bool
	// Test is true for license-test / sandbox purchases.
	Test bool
}

// Entitled reports whether the subscription currently grants access — active
// or still inside its grace period (a paying subscriber mid-renewal-lag).
func (s *Subscription) Entitled() bool {
	switch s.State {
	case StateActive, StateInGracePer:
		return true
	default:
		return false
	}
}

// --- Developer API: subscriptionsv2.get -----------------------------------

// rawSubscriptionV2 is the subset of SubscriptionPurchaseV2 we decode.
type rawSubscriptionV2 struct {
	SubscriptionState string    `json:"subscriptionState"`
	LatestOrderID     string    `json:"latestOrderId"`
	LinkedPurchaseTok string    `json:"linkedPurchaseToken"`
	AcknowledgeState  string    `json:"acknowledgementState"`
	TestPurchase      *struct{} `json:"testPurchase"`
	LineItems         []struct {
		ProductID  string `json:"productId"`
		ExpiryTime string `json:"expiryTime"` // RFC3339
	} `json:"lineItems"`
}

// GetSubscription fetches the authoritative state of the subscription
// identified by purchaseToken from the Play Developer API.
func (c *Client) GetSubscription(ctx context.Context, purchaseToken string) (*Subscription, error) {
	tok, err := c.accessToken(ctx)
	if err != nil {
		return nil, err
	}
	endpoint := fmt.Sprintf("%s/applications/%s/purchases/subscriptionsv2/tokens/%s",
		apiBase, url.PathEscape(c.pkg), url.PathEscape(purchaseToken))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := c.httpc.Do(req)
	if err != nil {
		return nil, fmt.Errorf("googleplay: subscriptionsv2.get: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("googleplay: subscriptionsv2.get status %d: %s", resp.StatusCode, string(body))
	}

	var raw rawSubscriptionV2
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, fmt.Errorf("googleplay: decode subscriptionsv2: %w", err)
	}

	sub := &Subscription{
		State:               SubscriptionState(raw.SubscriptionState),
		LatestOrderID:       raw.LatestOrderID,
		LinkedPurchaseToken: raw.LinkedPurchaseTok,
		Acknowledged:        raw.AcknowledgeState == "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED",
		Test:                raw.TestPurchase != nil,
	}
	for i, li := range raw.LineItems {
		if i == 0 {
			sub.ProductID = li.ProductID
		}
		if li.ExpiryTime == "" {
			continue
		}
		t, err := time.Parse(time.RFC3339, li.ExpiryTime)
		if err != nil {
			continue
		}
		if t.After(sub.Expiry) {
			sub.Expiry = t
		}
	}
	return sub, nil
}

// Acknowledge marks a subscription purchase as acknowledged. Google
// auto-refunds purchases not acknowledged within three days, so we call this
// after successfully provisioning the account. Idempotent on Google's side —
// acknowledging an already-acknowledged purchase is a no-op success.
func (c *Client) Acknowledge(ctx context.Context, productID, purchaseToken string) error {
	tok, err := c.accessToken(ctx)
	if err != nil {
		return err
	}
	endpoint := fmt.Sprintf("%s/applications/%s/purchases/subscriptions/%s/tokens/%s:acknowledge",
		apiBase, url.PathEscape(c.pkg), url.PathEscape(productID), url.PathEscape(purchaseToken))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader("{}"))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.httpc.Do(req)
	if err != nil {
		return fmt.Errorf("googleplay: acknowledge: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusNoContent {
		return fmt.Errorf("googleplay: acknowledge status %d: %s", resp.StatusCode, string(body))
	}
	return nil
}

// --- OAuth2 service-account JWT-bearer flow -------------------------------

// accessToken returns a cached OAuth2 access token, minting a fresh one when
// the cache is empty or within 60s of expiry.
func (c *Client) accessToken(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.token != "" && time.Now().Before(c.tokenExp.Add(-60*time.Second)) {
		return c.token, nil
	}
	assertion, err := c.signedJWT()
	if err != nil {
		return "", err
	}
	form := url.Values{}
	form.Set("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer")
	form.Set("assertion", assertion)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.sa.TokenURI,
		bytes.NewBufferString(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := c.httpc.Do(req)
	if err != nil {
		return "", fmt.Errorf("googleplay: token exchange: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("googleplay: token exchange status %d: %s", resp.StatusCode, string(body))
	}
	var tr struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.Unmarshal(body, &tr); err != nil {
		return "", fmt.Errorf("googleplay: decode token: %w", err)
	}
	if tr.AccessToken == "" {
		return "", fmt.Errorf("googleplay: empty access token")
	}
	c.token = tr.AccessToken
	c.tokenExp = time.Now().Add(time.Duration(tr.ExpiresIn) * time.Second)
	return c.token, nil
}

// signedJWT builds and RS256-signs the assertion JWT that requests an access
// token scoped to the Android Publisher API.
func (c *Client) signedJWT() (string, error) {
	now := time.Now()
	header := map[string]string{"alg": "RS256", "typ": "JWT"}
	claims := map[string]any{
		"iss":   c.sa.ClientEmail,
		"scope": androidPublisherScope,
		"aud":   c.sa.TokenURI,
		"iat":   now.Unix(),
		"exp":   now.Add(time.Hour).Unix(),
	}
	hJSON, err := json.Marshal(header)
	if err != nil {
		return "", err
	}
	cJSON, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	signingInput := b64url(hJSON) + "." + b64url(cJSON)
	digest := sha256.Sum256([]byte(signingInput))
	sig, err := rsa.SignPKCS1v15(rand.Reader, c.key, crypto.SHA256, digest[:])
	if err != nil {
		return "", fmt.Errorf("googleplay: sign jwt: %w", err)
	}
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(sig), nil
}

func b64url(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// --- Real-time Developer Notifications (Pub/Sub push) ---------------------

// Subscription notification type codes (DeveloperNotification.subscriptionNotification.notificationType).
const (
	NotifRecovered      = 1
	NotifRenewed        = 2
	NotifCanceled       = 3
	NotifPurchased      = 4
	NotifOnHold         = 5
	NotifInGracePeriod  = 6
	NotifRestarted      = 7
	NotifPriceConfirmed = 8
	NotifDeferred       = 9
	NotifPaused         = 10
	NotifPauseSchedule  = 11
	NotifRevoked        = 12
	NotifExpired        = 13
)

// PubSubEnvelope is the push-delivery wrapper Pub/Sub POSTs to the RTDN
// endpoint. The base64 Message.Data decodes to a DeveloperNotification.
type PubSubEnvelope struct {
	Message struct {
		Data        string `json:"data"`
		MessageID   string `json:"messageId"`
		PublishTime string `json:"publishTime"`
	} `json:"message"`
	Subscription string `json:"subscription"`
}

// DeveloperNotification is the decoded RTDN payload. Only the subscription and
// test sub-objects are relevant to us.
type DeveloperNotification struct {
	Version                  string `json:"version"`
	PackageName              string `json:"packageName"`
	EventTimeMillis          string `json:"eventTimeMillis"`
	SubscriptionNotification *struct {
		Version          string `json:"version"`
		NotificationType int    `json:"notificationType"`
		PurchaseToken    string `json:"purchaseToken"`
		SubscriptionID   string `json:"subscriptionId"`
	} `json:"subscriptionNotification"`
	TestNotification *struct {
		Version string `json:"version"`
	} `json:"testNotification"`
}

// DecodeNotification parses a Pub/Sub push body into a DeveloperNotification.
func DecodeNotification(body []byte) (*DeveloperNotification, error) {
	var env PubSubEnvelope
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("googleplay: decode pubsub envelope: %w", err)
	}
	if env.Message.Data == "" {
		return nil, fmt.Errorf("googleplay: empty pubsub message data")
	}
	raw, err := base64.StdEncoding.DecodeString(env.Message.Data)
	if err != nil {
		// Pub/Sub uses standard base64; tolerate URL-safe just in case.
		raw, err = base64.RawStdEncoding.DecodeString(env.Message.Data)
		if err != nil {
			return nil, fmt.Errorf("googleplay: decode notification data: %w", err)
		}
	}
	var n DeveloperNotification
	if err := json.Unmarshal(raw, &n); err != nil {
		return nil, fmt.Errorf("googleplay: decode developer notification: %w", err)
	}
	return &n, nil
}
