// Smoke-test CLI for wg.Controller. Lets us exercise Provision / Revoke
// end-to-end on a live concentrator without the Stripe + DB dependencies.
//
// Usage (on the concentrator, as root):
//
//	WG_SERVER_PUB=$(cat /etc/wireguard/server.pub) \
//	WG_ENDPOINT=fi1.cloakvpn.ai:51820 \
//	  ./smoke provision
//
//	# then, to undo:
//	./smoke revoke <client-wg-pubkey>
//
// Intentionally NOT shipped with the API — build from cmd/smoke/ on demand.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"regexp"

	"github.com/cloakvpn/api/internal/wg"
)

// usedIPsFromWG parses `wg show <iface> allowed-ips` to extract all already-
// assigned IPv4 addresses in the tunnel subnet. This mirrors the list the
// production HTTP handler gets from store.DevicesForAccount — without it,
// Provision will happily reassign a .2 that's already in use.
func usedIPsFromWG(iface string) ([]string, error) {
	out, err := exec.Command("wg", "show", iface, "allowed-ips").Output()
	if err != nil {
		return nil, err
	}
	// Output is: "<pubkey>\t10.99.0.2/32 fd42:99::2/128\n"
	// We only care about IPv4s in the form x.x.x.x/32.
	re := regexp.MustCompile(`(\d+\.\d+\.\d+\.\d+)/32`)
	var ips []string
	for _, m := range re.FindAllStringSubmatch(string(out), -1) {
		ips = append(ips, m[1])
	}
	return ips, nil
}

func main() {
	if len(os.Args) < 2 {
		die("usage: smoke provision | smoke revoke <wg-pubkey>")
	}
	c := wg.NewController(wg.Config{
		Iface:      envOr("WG_IFACE", "wg0"),
		ServerPub:  mustEnv("WG_SERVER_PUB"),
		Endpoint:   mustEnv("WG_ENDPOINT"),
		DNS:        envOr("WG_DNS", "10.99.0.1"),
		AllowedIPs: envOr("WG_ALLOWED_IPS", "0.0.0.0/0, ::/0"),
		SubnetCIDR: envOr("WG_SUBNET", "10.99.0.0/24"),
	})

	switch os.Args[1] {
	case "provision":
		used, err := usedIPsFromWG(envOr("WG_IFACE", "wg0"))
		if err != nil {
			die("read used IPs: " + err.Error())
		}
		fmt.Fprintf(os.Stderr, "used IPs (from wg show): %v\n", used)
		cfg, err := c.Provision(used)
		if err != nil {
			die("provision: " + err.Error())
		}
		// Rosenpass pubkeys are ~700KB base64 (Classic McEliece-460896);
		// trim to a preview so stdout doesn't blow up.
		display := *cfg
		display.RosenpassClientPK = preview(display.RosenpassClientPK, 80)
		display.RosenpassClientSK = preview(display.RosenpassClientSK, 80)
		display.RosenpassPeerPub = preview(display.RosenpassPeerPub, 80)
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(display)
		// Also emit the raw client pubkey on a dedicated line so the operator
		// can copy-paste it into the revoke step without parsing JSON.
		fmt.Fprintf(os.Stderr, "\nCLIENT_WG_PUB=%s\n", cfg.InterfacePublicKey)
	case "revoke":
		if len(os.Args) < 3 {
			die("usage: smoke revoke <wg-pubkey>")
		}
		if err := c.Revoke(os.Args[2]); err != nil {
			die("revoke: " + err.Error())
		}
		fmt.Println("ok")
	default:
		die("unknown subcommand: " + os.Args[1])
	}
}

func preview(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "... (" + fmt.Sprintf("%d total chars", len(s)) + ")"
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		die("missing env var: " + k)
	}
	return v
}

func die(msg string) {
	fmt.Fprintln(os.Stderr, msg)
	os.Exit(1)
}
