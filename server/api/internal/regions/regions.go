// Package regions holds the multi-region registry and the authenticated
// HTTP client that the central cloakvpn-api uses to drive each
// concentrator's regionsvc (see cmd/regionsvc and docs/BILLING_INTEGRATION.md
// §7).
//
// The central API owns accounts, billing and the database; it never touches
// WireGuard directly. To provision a peer it looks the chosen region up in
// the Registry and calls that box's regionsvc over an authenticated
// internal channel.
package regions

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/cloakvpn/api/internal/wg"
)

// Region is one concentrator the central API can provision onto.
type Region struct {
	ID  string `json:"id"`  // e.g. "us-west-1", "madrid"
	URL string `json:"url"` // base URL of that box's regionsvc, e.g. http://5.78.203.171:8090
}

// Registry is the immutable set of regions, loaded once at startup.
type Registry struct {
	byID map[string]Region
	ids  []string
}

// Load reads the region list from a JSON file — an array of {id,url}
// objects. Fails fast on a malformed or empty file so a misconfiguration
// surfaces at boot, not on the first customer provision.
func Load(path string) (*Registry, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var list []Region
	if err := json.Unmarshal(raw, &list); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	if len(list) == 0 {
		return nil, fmt.Errorf("%s: no regions configured", path)
	}
	r := &Registry{byID: make(map[string]Region, len(list))}
	for _, reg := range list {
		if reg.ID == "" || reg.URL == "" {
			return nil, fmt.Errorf("%s: region with empty id or url", path)
		}
		if _, dup := r.byID[reg.ID]; dup {
			return nil, fmt.Errorf("%s: duplicate region id %q", path, reg.ID)
		}
		r.byID[reg.ID] = reg
		r.ids = append(r.ids, reg.ID)
	}
	return r, nil
}

// Get returns a region by id; ok is false if the id is not configured.
func (r *Registry) Get(id string) (reg Region, ok bool) {
	reg, ok = r.byID[id]
	return
}

// IDs lists every configured region id, in file order.
func (r *Registry) IDs() []string { return r.ids }

// ErrRegionUnavailable is returned when a region's regionsvc cannot be
// reached or fails to provision — distinct from a bad request, so the
// caller can map it to a 502 rather than a 400.
var ErrRegionUnavailable = errors.New("region unavailable")

// Client calls the regionsvc instance on each concentrator.
type Client struct {
	http   *http.Client
	secret string
}

// NewClient builds the regionsvc client. secret is REGION_INTERNAL_SECRET,
// the single value shared by the central API and every region.
func NewClient(secret string) *Client {
	return &Client{
		// Provisioning restarts rosenpass on the target box, so a call can
		// take several seconds — keep the timeout generous.
		http:   &http.Client{Timeout: 90 * time.Second},
		secret: secret,
	}
}

type provisionBody struct {
	WGPubkey        string `json:"wg_pubkey"`
	RosenpassPubkey string `json:"rosenpass_pubkey"`
	IP              string `json:"ip"`
}

type revokeBody struct {
	WGPubkey string `json:"wg_pubkey"`
}

// Provision asks the region's regionsvc to add a WireGuard + Rosenpass peer
// at ip and returns the resulting client config. The ip must already be
// allocated by the caller from the database.
func (c *Client) Provision(reg Region, wgPubkey, rosenpassPubkey, ip string) (*wg.ClientConfig, error) {
	body, _ := json.Marshal(provisionBody{
		WGPubkey:        wgPubkey,
		RosenpassPubkey: rosenpassPubkey,
		IP:              ip,
	})
	resp, err := c.do(reg, "/internal/provision", body)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, fmt.Errorf("%w: %s provision HTTP %d: %s",
			ErrRegionUnavailable, reg.ID, resp.StatusCode, bytes.TrimSpace(msg))
	}
	var cfg wg.ClientConfig
	if err := json.NewDecoder(resp.Body).Decode(&cfg); err != nil {
		return nil, fmt.Errorf("%w: %s provision: decoding config: %v",
			ErrRegionUnavailable, reg.ID, err)
	}
	return &cfg, nil
}

// Revoke asks the region's regionsvc to remove a peer. Idempotent — a peer
// that is already gone is not an error.
func (c *Client) Revoke(reg Region, wgPubkey string) error {
	body, _ := json.Marshal(revokeBody{WGPubkey: wgPubkey})
	resp, err := c.do(reg, "/internal/revoke", body)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("%w: %s revoke HTTP %d: %s",
			ErrRegionUnavailable, reg.ID, resp.StatusCode, bytes.TrimSpace(msg))
	}
	return nil
}

func (c *Client) do(reg Region, path string, body []byte) (*http.Response, error) {
	req, err := http.NewRequest(http.MethodPost, reg.URL+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+c.secret)
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %s: %v", ErrRegionUnavailable, reg.ID, err)
	}
	return resp, nil
}

// NextFreeIP returns the lowest unused IPv4 address in subnetCIDR, skipping
// .0 (network), .1 (the concentrator) and .255 (broadcast). used is the set
// of tunnel IPs already allocated in the target region — each concentrator
// runs its own subnet, so allocation only needs to avoid that region's set.
func NextFreeIP(used []string, subnetCIDR string) (string, error) {
	_, ipnet, err := net.ParseCIDR(subnetCIDR)
	if err != nil {
		return "", err
	}
	ip := ipnet.IP.To4()
	if ip == nil {
		return "", fmt.Errorf("subnet %s is not IPv4", subnetCIDR)
	}
	taken := make(map[string]struct{}, len(used))
	for _, u := range used {
		taken[u] = struct{}{}
	}
	for i := 2; i < 255; i++ {
		cand := net.IPv4(ip[0], ip[1], ip[2], byte(i)).String()
		if _, t := taken[cand]; !t {
			return cand, nil
		}
	}
	return "", fmt.Errorf("subnet %s exhausted", subnetCIDR)
}
