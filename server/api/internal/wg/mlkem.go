package wg

// ML-KEM-768 (FIPS 203) provisioning path.
//
// The device generates a fresh ML-KEM-768 key pair for every provision and
// sends only the encapsulation (public) key. THIS box, the WireGuard endpoint,
// encapsulates against it, derives the WireGuard preshared key from the shared
// secret, installs it on the peer, and returns only the ciphertext. The shared
// secret and the PSK never leave this box, so the central API and the links it
// uses carry public values only.
//
// A peer provisioned this way does not use Rosenpass: any Rosenpass
// registration for the same WireGuard key is removed first so
// cloak-psk-installer can never overwrite the ML-KEM-derived PSK.

import (
	"crypto/hkdf"
	"crypto/mlkem"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// PQKEMMLKEM768 is the value of ClientConfig.PQKEM for this path.
const PQKEMMLKEM768 = "ML-KEM-768"

// mlkem768PSKInfo is the HKDF info string. Clients must use the same value.
const mlkem768PSKInfo = "lattice-vpn/mlkem768-wg-psk/v1"

// mlkem768Respond encapsulates against the client's ML-KEM-768 encapsulation
// key and derives the 32-byte WireGuard PSK:
//
//	PSK = HKDF-SHA256(ikm = shared secret,
//	                  salt = client WG public key || server WG public key,
//	                  info = "lattice-vpn/mlkem768-wg-psk/v1")
//
// Binding both WireGuard public keys into the salt ties the PSK to this one
// peer pair. It returns the ciphertext for the client and the PSK.
func mlkem768Respond(ekRaw, clientWGPub, serverWGPub []byte) (ct, psk []byte, err error) {
	if len(clientWGPub) != 32 || len(serverWGPub) != 32 {
		return nil, nil, fmt.Errorf("wireguard public keys must be 32 bytes")
	}
	ek, err := mlkem.NewEncapsulationKey768(ekRaw)
	if err != nil {
		return nil, nil, fmt.Errorf("invalid ML-KEM-768 encapsulation key: %w", err)
	}
	ss, ct := ek.Encapsulate()
	salt := make([]byte, 0, 64)
	salt = append(salt, clientWGPub...)
	salt = append(salt, serverWGPub...)
	psk, err = hkdf.Key(sha256.New, ss, salt, mlkem768PSKInfo, 32)
	if err != nil {
		return nil, nil, fmt.Errorf("derive psk: %w", err)
	}
	return ct, psk, nil
}

// ProvisionMLKEM768 adds (or re-keys) a WireGuard peer whose preshared key is
// derived from an ML-KEM-768 exchange. wgPubkeyB64 is the device's WireGuard
// public key; mlkemPubB64 is its 1184-byte ML-KEM-768 encapsulation key.
// IP handling matches ProvisionWithKeys.
func (c *Controller) ProvisionMLKEM768(usedIPs []string, reuseIP, wgPubkeyB64, mlkemPubB64 string) (*ClientConfig, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	wgPub := strings.TrimSpace(wgPubkeyB64)
	wgRaw, err := base64.StdEncoding.DecodeString(wgPub)
	if err != nil || len(wgRaw) != 32 {
		return nil, fmt.Errorf("wg public key must be base64 of 32 bytes")
	}
	serverRaw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(c.cfg.ServerPub))
	if err != nil || len(serverRaw) != 32 {
		return nil, fmt.Errorf("server wg public key is not base64 of 32 bytes")
	}
	ekRaw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(mlkemPubB64))
	if err != nil {
		return nil, fmt.Errorf("mlkem768 public key is not valid base64")
	}

	// All validation and crypto happens before any system state is touched.
	ct, psk, err := mlkem768Respond(ekRaw, wgRaw, serverRaw)
	if err != nil {
		return nil, err
	}

	ip := strings.TrimSpace(reuseIP)
	if ip == "" {
		ip, err = c.nextFreeIP(usedIPs)
		if err != nil {
			return nil, err
		}
	}

	// Drop any Rosenpass registration for this WireGuard key (a device that
	// previously provisioned the legacy way), mirroring Revoke's order.
	peerName := peerNameFromWG(wgPub)
	publicPath := filepath.Join(c.cfg.RosenpassDir, peerName+".rosenpass-public")
	rpChanged, err := c.removeRosenpassPeer(publicPath)
	if err != nil {
		return nil, fmt.Errorf("remove from server.toml: %w", err)
	}
	_ = os.Remove(publicPath)
	_ = os.Remove(filepath.Join(c.cfg.RosenpassDir, peerName+".rosenpass-secret"))
	_ = os.Remove(filepath.Join(wgConfigDir, peerName+".pub"))
	if err := c.revokePeerLive(peerName, rpChanged); err != nil {
		return nil, fmt.Errorf("drop rosenpass peer: %w", err)
	}

	// Install the peer with its PSK. The key goes over stdin, never argv.
	cmd := exec.Command("wg", "set", c.cfg.Iface,
		"peer", wgPub,
		"preshared-key", "/dev/stdin",
		"allowed-ips", ip+"/32")
	cmd.Stdin = strings.NewReader(base64.StdEncoding.EncodeToString(psk) + "\n")
	if out, err := cmd.CombinedOutput(); err != nil {
		return nil, fmt.Errorf("wg set: %w: %s", err, out)
	}
	if out, err := exec.Command("wg-quick", "save", c.cfg.Iface).CombinedOutput(); err != nil {
		return nil, fmt.Errorf("wg-quick save: %w: %s", err, out)
	}

	return &ClientConfig{
		InterfacePublicKey: wgPub,
		InterfaceAddress:   ip + "/32, " + ipv6Blackhole,
		InterfaceDNS:       c.cfg.DNS,
		PeerPublicKey:      c.cfg.ServerPub,
		PeerEndpoint:       c.cfg.Endpoint,
		PeerAllowedIPs:     c.cfg.AllowedIPs,
		AssignedIP:         ip,
		PQKEM:              PQKEMMLKEM768,
		MLKEM768Ciphertext: base64.StdEncoding.EncodeToString(ct),
	}, nil
}
