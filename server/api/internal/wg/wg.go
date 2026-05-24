// Package wg is a thin wrapper over `wg` + `ip` + `rosenpass` system commands,
// called from the API when we provision a new peer for a paying customer.
//
// Phase 0 is intentionally shell-out: it keeps us aligned with server/scripts/
// (specifically add-peer.sh, which is the reference behaviour this code ports
// to Go) and avoids pulling in wgctrl + a netlink dance. If we outgrow it,
// this is the single file to replace.
//
// Trust model (Option A — server-generated Rosenpass identity):
//
//	The server runs `rosenpass gen-keys` on behalf of the client, appends a
//	[[peers]] block to /etc/rosenpass/server.toml, restarts the rosenpass
//	service, and returns the keys to the client base64-encoded. This matches
//	server/scripts/add-peer.sh exactly. If the privacy posture ever needs to
//	upgrade, the migration is: have the client POST only its Rosenpass public
//	key and skip the gen-keys step here. See the AI Shield positioning doc
//	for the revenue-target rationale behind picking Option A for Phase 0.
//
// Runtime assumptions:
//
//   - The API process runs as root (or has CAP_NET_ADMIN + write access to
//     /etc/wireguard, /etc/rosenpass, and permission to `systemctl restart`
//     cloak-rosenpass.service). Setup.sh configures everything as root-owned.
//   - Concurrent Provision / Revoke calls are serialized via Controller.mu
//     so server.toml edits can't race with each other or with the restart.
//   - A Provision call causes a ~2-5s PSK-exchange interruption for OTHER
//     peers because rosenpass has to be restarted (it doesn't support SIGHUP
//     reload yet). WireGuard is NOT restarted, so existing data-plane tunnels
//     stay up during that window; they just temporarily fall back to the
//     last-rotated PSK until rosenpass comes back and issues fresh ones.
package wg

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
)

type Config struct {
	Iface      string // wg0
	ServerPub  string // server's WireGuard public key (base64)
	Endpoint   string // fi1.cloakvpn.ai:51820
	DNS        string // 10.99.0.1
	AllowedIPs string // "0.0.0.0/0, ::/0"
	SubnetCIDR string // 10.99.0.0/24

	// Rosenpass paths / service — defaults match server/scripts/setup.sh.
	// Leave these zero-valued in production; NewController fills them in.
	// Override them in tests to point at a tmpdir.
	RosenpassDir           string // /etc/rosenpass
	ServerTomlPath         string // /etc/rosenpass/server.toml
	ServiceName            string // cloak-rosenpass.service
	ServerRosenpassPubPath string // /etc/rosenpass/server.rosenpass-public
	RosenpassPort          int    // 9999
}

type Controller struct {
	cfg Config

	// mu serializes mutations of /etc/rosenpass/server.toml and the
	// subsequent service restart, so two concurrent Provision calls can't
	// corrupt the file or both restart the service back-to-back.
	mu sync.Mutex
}

func NewController(c Config) *Controller {
	// Fill in zero-value Rosenpass fields with production defaults so the
	// HTTP handler doesn't have to know about rosenpass paths.
	if c.RosenpassDir == "" {
		c.RosenpassDir = "/etc/rosenpass"
	}
	if c.ServerTomlPath == "" {
		c.ServerTomlPath = filepath.Join(c.RosenpassDir, "server.toml")
	}
	if c.ServiceName == "" {
		c.ServiceName = "cloak-rosenpass.service"
	}
	if c.ServerRosenpassPubPath == "" {
		c.ServerRosenpassPubPath = filepath.Join(c.RosenpassDir, "server.rosenpass-public")
	}
	if c.RosenpassPort == 0 {
		c.RosenpassPort = 9999
	}
	return &Controller{cfg: c}
}

// ClientConfig is what we hand back to the app. All Rosenpass material is
// base64-encoded so it fits cleanly in a JSON response body.
type ClientConfig struct {
	InterfacePrivateKey string // base64 (client wg privkey)
	InterfacePublicKey  string // base64 (client wg pubkey — also what we store for later Revoke)
	InterfaceAddress    string // "10.99.0.5/32"
	InterfaceDNS        string
	PeerPublicKey       string // server's wg pub
	PeerEndpoint        string // fi1.cloakvpn.ai:51820
	PeerAllowedIPs      string
	RosenpassPeerPub    string // base64 of server's rosenpass static pub
	RosenpassListen     string // fi1.cloakvpn.ai:9999
	RosenpassClientSK   string // base64 of client rosenpass secret
	RosenpassClientPK   string // base64 of client rosenpass public
	AssignedIP          string // "10.99.0.5"
}

// Provision is the end-to-end "add a new device" flow. It:
//  1. Picks the next free IP in SubnetCIDR.
//  2. Runs `wg genkey` / `wg pubkey` to mint a WireGuard keypair.
//  3. Runs `rosenpass gen-keys` to mint a Rosenpass keypair.
//  4. Registers the Rosenpass pubkey in /etc/rosenpass/server.toml.
//  5. Adds the peer to the running wg interface + persists to wg0.conf.
//  6. Restarts cloak-rosenpass.service so the new [[peers]] block is loaded.
//  7. Returns a ClientConfig the app encodes into its TunnelManager.
//
// usedIPs is the set of IPs already allocated (pulled from store.Devices).
func (c *Controller) Provision(usedIPs []string) (*ClientConfig, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	ip, err := c.nextFreeIP(usedIPs)
	if err != nil {
		return nil, err
	}

	// --- WireGuard keypair ------------------------------------------------
	wgPriv, err := run("wg", "genkey")
	if err != nil {
		return nil, fmt.Errorf("wg genkey: %w", err)
	}
	wgPriv = strings.TrimSpace(wgPriv)
	wgPub, err := runStdin(wgPriv, "wg", "pubkey")
	if err != nil {
		return nil, fmt.Errorf("wg pubkey: %w", err)
	}
	wgPub = strings.TrimSpace(wgPub)

	// Derive a stable on-disk peer name from the WG pubkey so Revoke() can
	// find the rosenpass files later without us storing a mapping. 12 hex
	// chars of sha256 -> 48 bits of collision resistance, ample at <500 peers.
	peerName := peerNameFromWG(wgPub)
	secretPath := filepath.Join(c.cfg.RosenpassDir, peerName+".rosenpass-secret")
	publicPath := filepath.Join(c.cfg.RosenpassDir, peerName+".rosenpass-public")

	// --- Rosenpass keypair -----------------------------------------------
	// Note: rosenpass uses Classic McEliece-460896, so the public key file is
	// ~524KB on disk (~700KB base64). This is normal — do NOT treat the size
	// as a bug.
	if out, err := exec.Command("rosenpass", "gen-keys",
		"--secret-key", secretPath,
		"--public-key", publicPath).CombinedOutput(); err != nil {
		return nil, fmt.Errorf("rosenpass gen-keys: %w: %s", err, out)
	}
	// rosenpass creates files with the process umask (default 0022 ⇒ 0644).
	// The secret MUST be 0600 so other users on the box can't read it; match
	// the setup.sh convention of 0600 on the public too.
	if err := os.Chmod(secretPath, 0600); err != nil {
		_ = os.Remove(secretPath)
		_ = os.Remove(publicPath)
		return nil, fmt.Errorf("chmod rosenpass secret: %w", err)
	}
	if err := os.Chmod(publicPath, 0600); err != nil {
		_ = os.Remove(secretPath)
		_ = os.Remove(publicPath)
		return nil, fmt.Errorf("chmod rosenpass public: %w", err)
	}

	// Read both keys back so we can return them to the client. We do this
	// BEFORE touching wg/server.toml so a read failure doesn't leave us in
	// a partially-applied state.
	secretB64, err := readFileB64(secretPath)
	if err != nil {
		_ = os.Remove(secretPath)
		_ = os.Remove(publicPath)
		return nil, fmt.Errorf("read rosenpass secret: %w", err)
	}
	publicB64, err := readFileB64(publicPath)
	if err != nil {
		_ = os.Remove(secretPath)
		_ = os.Remove(publicPath)
		return nil, fmt.Errorf("read rosenpass public: %w", err)
	}

	// --- Register in server.toml -----------------------------------------
	if err := c.appendRosenpassPeer(peerName, publicPath); err != nil {
		_ = os.Remove(secretPath)
		_ = os.Remove(publicPath)
		return nil, fmt.Errorf("append to server.toml: %w", err)
	}

	// --- Add WG peer ------------------------------------------------------
	// AllowedIPs on the server side is just the peer's /32 (so return traffic
	// is routed back to that peer). The client-side AllowedIPs (everything
	// routed through the tunnel) is set in the ClientConfig below.
	if out, err := exec.Command("wg", "set", c.cfg.Iface,
		"peer", wgPub,
		"allowed-ips", ip+"/32").CombinedOutput(); err != nil {
		return nil, fmt.Errorf("wg set: %w: %s", err, out)
	}
	// Record the peer's WG pubkey for cloak-psk-installer.sh — without this
	// the rosenpass PSK is never installed onto the peer.
	if err := writePeerWGPubkey(peerName, wgPub); err != nil {
		return nil, fmt.Errorf("write peer wg pubkey: %w", err)
	}
	// Persist to /etc/wireguard/wg0.conf so it survives a reboot.
	if out, err := exec.Command("wg-quick", "save", c.cfg.Iface).CombinedOutput(); err != nil {
		return nil, fmt.Errorf("wg-quick save: %w: %s", err, out)
	}

	// --- Restart rosenpass so the new peer is picked up ------------------
	if err := c.restartRosenpass(); err != nil {
		return nil, fmt.Errorf("restart rosenpass: %w", err)
	}

	// Read the server's rosenpass pubkey so the client can pin its identity.
	serverRPB64, err := readFileB64(c.cfg.ServerRosenpassPubPath)
	if err != nil {
		return nil, fmt.Errorf("read server rosenpass pub: %w", err)
	}

	host := strings.Split(c.cfg.Endpoint, ":")[0]
	return &ClientConfig{
		InterfacePrivateKey: wgPriv,
		InterfacePublicKey:  wgPub,
		InterfaceAddress:    ip + "/32",
		InterfaceDNS:        c.cfg.DNS,
		PeerPublicKey:       c.cfg.ServerPub,
		PeerEndpoint:        c.cfg.Endpoint,
		PeerAllowedIPs:      c.cfg.AllowedIPs,
		RosenpassPeerPub:    serverRPB64,
		RosenpassListen:     fmt.Sprintf("%s:%d", host, c.cfg.RosenpassPort),
		RosenpassClientSK:   secretB64,
		RosenpassClientPK:   publicB64,
		AssignedIP:          ip,
	}, nil
}

// ProvisionWithKeys is the "add a new device" flow when the CLIENT has
// generated its own WireGuard + Rosenpass keypairs and sends only the
// public keys — the no-account model, where private keys never leave the
// device. Unlike Provision it generates nothing: it writes the client's
// Rosenpass public key to disk, registers both keys, and returns a
// ClientConfig with the private-key fields left empty (the app holds them).
//
// wgPubkeyB64 is a standard 32-byte WireGuard public key; rosenpassPubkeyB64
// is the client's Classic McEliece Rosenpass public key (~524 KB raw).
func (c *Controller) ProvisionWithKeys(usedIPs []string, reuseIP, wgPubkeyB64, rosenpassPubkeyB64 string) (*ClientConfig, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	wgPub := strings.TrimSpace(wgPubkeyB64)
	rpPubB64 := strings.TrimSpace(rosenpassPubkeyB64)

	// Validate the inputs are the right KIND of key BEFORE touching any
	// system state — a malformed Rosenpass key would crash the rosenpass
	// service for every peer on the next restart.
	wgRaw, err := base64.StdEncoding.DecodeString(wgPub)
	if err != nil || len(wgRaw) != 32 {
		return nil, fmt.Errorf("wg public key must be base64 of 32 bytes")
	}
	rpRaw, err := base64.StdEncoding.DecodeString(rpPubB64)
	if err != nil {
		return nil, fmt.Errorf("rosenpass public key is not valid base64")
	}
	// A Classic McEliece-460896 public key is ~524 KB; a 32-byte wg key
	// sent here by mistake is the realistic error to catch.
	if len(rpRaw) < 500_000 {
		return nil, fmt.Errorf("rosenpass public key too small (%d bytes) — not a McEliece key", len(rpRaw))
	}

	// IP allocation: a re-provision of an existing device passes that
	// device's current tunnel address as reuseIP and keeps it; a brand-new
	// device passes reuseIP="" and gets the next IP free across EVERY peer
	// (usedIPs must be the global set — see store.AllDeviceIPs).
	ip := strings.TrimSpace(reuseIP)
	if ip == "" {
		ip, err = c.nextFreeIP(usedIPs)
		if err != nil {
			return nil, err
		}
	}

	// Peer name is derived from the wg pubkey, exactly as in Provision, so
	// Revoke() can still find the rosenpass file without a lookup table.
	peerName := peerNameFromWG(wgPub)
	publicPath := filepath.Join(c.cfg.RosenpassDir, peerName+".rosenpass-public")

	if err := os.WriteFile(publicPath, rpRaw, 0600); err != nil {
		return nil, fmt.Errorf("write rosenpass public: %w", err)
	}

	// --- Register in server.toml -----------------------------------------
	if err := c.appendRosenpassPeer(peerName, publicPath); err != nil {
		_ = os.Remove(publicPath)
		return nil, fmt.Errorf("append to server.toml: %w", err)
	}

	// --- Add WG peer ------------------------------------------------------
	if out, err := exec.Command("wg", "set", c.cfg.Iface,
		"peer", wgPub,
		"allowed-ips", ip+"/32").CombinedOutput(); err != nil {
		return nil, fmt.Errorf("wg set: %w: %s", err, out)
	}
	// Record the peer's WG pubkey for cloak-psk-installer.sh — without this
	// the rosenpass PSK is never installed onto the peer.
	if err := writePeerWGPubkey(peerName, wgPub); err != nil {
		return nil, fmt.Errorf("write peer wg pubkey: %w", err)
	}
	if out, err := exec.Command("wg-quick", "save", c.cfg.Iface).CombinedOutput(); err != nil {
		return nil, fmt.Errorf("wg-quick save: %w: %s", err, out)
	}

	// --- Restart rosenpass so the new peer is picked up ------------------
	if err := c.restartRosenpass(); err != nil {
		return nil, fmt.Errorf("restart rosenpass: %w", err)
	}

	serverRPB64, err := readFileB64(c.cfg.ServerRosenpassPubPath)
	if err != nil {
		return nil, fmt.Errorf("read server rosenpass pub: %w", err)
	}

	host := strings.Split(c.cfg.Endpoint, ":")[0]
	// Private-key fields are intentionally empty: the device generated and
	// kept its own WireGuard + Rosenpass secrets.
	return &ClientConfig{
		InterfacePublicKey: wgPub,
		InterfaceAddress:   ip + "/32",
		InterfaceDNS:       c.cfg.DNS,
		PeerPublicKey:      c.cfg.ServerPub,
		PeerEndpoint:       c.cfg.Endpoint,
		PeerAllowedIPs:     c.cfg.AllowedIPs,
		RosenpassPeerPub:   serverRPB64,
		RosenpassListen:    fmt.Sprintf("%s:%d", host, c.cfg.RosenpassPort),
		RosenpassClientPK:  rpPubB64,
		AssignedIP:         ip,
	}, nil
}

// Revoke removes a peer from WireGuard AND Rosenpass, then restarts the
// Rosenpass service to drop the now-defunct [[peers]] block. Idempotent: if
// the peer files are already gone, the call still succeeds as long as the
// WG removal works.
func (c *Controller) Revoke(wgPubkey string) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	wgPubkey = strings.TrimSpace(wgPubkey)
	peerName := peerNameFromWG(wgPubkey)

	// WireGuard side.
	if out, err := exec.Command("wg", "set", c.cfg.Iface, "peer", wgPubkey, "remove").CombinedOutput(); err != nil {
		return fmt.Errorf("wg set remove: %w: %s", err, out)
	}
	if out, err := exec.Command("wg-quick", "save", c.cfg.Iface).CombinedOutput(); err != nil {
		return fmt.Errorf("wg-quick save: %w: %s", err, out)
	}

	// Rosenpass side. Remove the [[peers]] block first, THEN delete the key
	// files, so an interrupted Revoke can be retried safely (server.toml
	// never points at a deleted file).
	publicPath := filepath.Join(c.cfg.RosenpassDir, peerName+".rosenpass-public")
	secretPath := filepath.Join(c.cfg.RosenpassDir, peerName+".rosenpass-secret")

	if err := c.removeRosenpassPeer(publicPath); err != nil {
		return fmt.Errorf("remove from server.toml: %w", err)
	}
	_ = os.Remove(publicPath)
	_ = os.Remove(secretPath)
	_ = os.Remove(filepath.Join(wgConfigDir, peerName+".pub"))

	if err := c.restartRosenpass(); err != nil {
		return fmt.Errorf("restart rosenpass: %w", err)
	}
	return nil
}

// appendRosenpassPeer appends a new [[peers]] block to server.toml using a
// write-to-temp + atomic-rename so a crash or ENOSPC mid-write can't leave
// the config file partially populated.
func (c *Controller) appendRosenpassPeer(peerName, publicPath string) error {
	// Idempotent: re-provisioning an existing device would otherwise append
	// a second [[peers]] block for the same peer. Drop any existing block
	// for this peer first, so the result is always exactly one block.
	if err := c.removeRosenpassPeer(publicPath); err != nil {
		return err
	}

	// protocol_version = "V03" MUST be present. Without it rosenpass falls
	// back to an older protocol and the handshake with a V03 client silently
	// fails — no PSK is ever derived, so the tunnel never goes post-quantum.
	// Every peer block server/scripts/add-peer.sh writes carries this line;
	// this Go port has to match it.
	block := fmt.Sprintf("\n[[peers]]\npublic_key = %q\nkey_out = \"/run/rosenpass/psk-%s\"\nprotocol_version = \"V03\"\n",
		publicPath, peerName)

	existing, err := os.ReadFile(c.cfg.ServerTomlPath)
	if err != nil {
		return err
	}

	tmp, err := os.CreateTemp(filepath.Dir(c.cfg.ServerTomlPath), "server.toml.*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	// Clean up on any error path before the rename.
	defer func() {
		if _, err := os.Stat(tmpName); err == nil {
			_ = os.Remove(tmpName)
		}
	}()

	if _, err := tmp.Write(existing); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.WriteString(block); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0600); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, c.cfg.ServerTomlPath)
}

// removeRosenpassPeer rewrites server.toml without the [[peers]] block whose
// public_key value references publicPath. Buffers each block as it's read and
// emits it only when the *next* block starts (or EOF is reached); if the
// buffered block matches, it's silently dropped.
//
// The server.toml format here is purely line-oriented flat TOML — no nested
// tables — which is why simple text manipulation is safe instead of pulling
// in a full TOML parser.
func (c *Controller) removeRosenpassPeer(publicPath string) error {
	f, err := os.Open(c.cfg.ServerTomlPath)
	if err != nil {
		return err
	}

	var (
		out     bytes.Buffer
		inBlock bool
		block   strings.Builder
	)

	flush := func() {
		if !inBlock {
			return
		}
		if strings.Contains(block.String(), publicPath) {
			// Drop this block.
			block.Reset()
			inBlock = false
			return
		}
		out.WriteString(block.String())
		block.Reset()
		inBlock = false
	}

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.TrimSpace(line) == "[[peers]]" {
			flush()
			inBlock = true
			block.WriteString(line)
			block.WriteString("\n")
			continue
		}
		if inBlock {
			block.WriteString(line)
			block.WriteString("\n")
		} else {
			out.WriteString(line)
			out.WriteString("\n")
		}
	}
	flush()
	f.Close()
	if err := scanner.Err(); err != nil {
		return err
	}

	tmp, err := os.CreateTemp(filepath.Dir(c.cfg.ServerTomlPath), "server.toml.*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer func() {
		if _, err := os.Stat(tmpName); err == nil {
			_ = os.Remove(tmpName)
		}
	}()

	if _, err := tmp.Write(out.Bytes()); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0600); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, c.cfg.ServerTomlPath)
}

func (c *Controller) restartRosenpass() error {
	if out, err := exec.Command("systemctl", "restart", c.cfg.ServiceName).CombinedOutput(); err != nil {
		return fmt.Errorf("systemctl restart %s: %w: %s", c.cfg.ServiceName, err, out)
	}
	return nil
}

func (c *Controller) nextFreeIP(used []string) (string, error) {
	_, ipnet, err := net.ParseCIDR(c.cfg.SubnetCIDR)
	if err != nil {
		return "", err
	}
	skip := map[string]struct{}{}
	for _, u := range used {
		skip[u] = struct{}{}
	}
	ip := ipnet.IP.To4()
	// Reserve .0 (network), .1 (server), .255 (broadcast).
	for i := 2; i < 255; i++ {
		candidate := net.IPv4(ip[0], ip[1], ip[2], byte(i)).String()
		if _, taken := skip[candidate]; taken {
			continue
		}
		return candidate, nil
	}
	return "", fmt.Errorf("subnet %s exhausted", c.cfg.SubnetCIDR)
}

// peerNameFromWG derives a stable filesystem-safe peer name from the WG
// public key so Revoke() can find the rosenpass files without a lookup
// table. 12 hex chars = 48 bits of collision resistance; ample at <500 peers.
func peerNameFromWG(wgPubkey string) string {
	sum := sha256.Sum256([]byte(strings.TrimSpace(wgPubkey)))
	return "peer-" + hex.EncodeToString(sum[:6])
}

// wgConfigDir is wg-quick's config directory.
const wgConfigDir = "/etc/wireguard"

// writePeerWGPubkey records a peer's WireGuard public key at
// /etc/wireguard/<peerName>.pub. cloak-psk-installer.sh reads this file
// to map a rosenpass PSK (/run/rosenpass/psk-<peerName>) back to the WG
// peer it must be applied to. WITHOUT it the post-quantum PSK is derived
// but never installed on the peer, so the tunnel silently never goes
// post-quantum and ultimately fails the client-side rotation watchdog.
func writePeerWGPubkey(peerName, wgPubkey string) error {
	path := filepath.Join(wgConfigDir, peerName+".pub")
	return os.WriteFile(path, []byte(strings.TrimSpace(wgPubkey)+"\n"), 0644)
}

func readFileB64(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(b), nil
}

func run(name string, args ...string) (string, error) {
	var buf bytes.Buffer
	cmd := exec.Command(name, args...)
	cmd.Stdout = &buf
	if err := cmd.Run(); err != nil {
		return "", err
	}
	return buf.String(), nil
}

func runStdin(stdin, name string, args ...string) (string, error) {
	var buf bytes.Buffer
	cmd := exec.Command(name, args...)
	cmd.Stdin = strings.NewReader(stdin)
	cmd.Stdout = &buf
	if err := cmd.Run(); err != nil {
		return "", err
	}
	return buf.String(), nil
}
