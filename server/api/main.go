// Cloak VPN API — Phase 0 scaffold.
//
// Responsibilities:
//   - Serve Stripe webhooks (checkout.session.completed, customer.subscription.*)
//     and maintain an account → tier → device-limit record.
//   - Issue short-lived device configs (WireGuard + Rosenpass keys) for paying
//     customers, enforcing the Basic/Pro device cap.
//   - Stay simple enough to run on the same Hetzner CX22 as wg + rosenpass.
//
// Explicit non-goals for Phase 0:
//   - Rate limiting, IP banning, captcha (Cloudflare in front handles this).
//   - Anything that requires writing a request log to disk. We log to stderr
//     (journald) only, and journald is configured RAM-only on the box.
package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	httpx "github.com/cloakvpn/api/internal/http"
	"github.com/cloakvpn/api/internal/store"
	"github.com/cloakvpn/api/internal/stripe"
	"github.com/cloakvpn/api/internal/wg"
)

func main() {
	cfg := loadConfig()

	db, err := store.Open(cfg.DBPath)
	if err != nil {
		log.Fatalf("store open: %v", err)
	}
	defer db.Close()

	wgc := wg.NewController(wg.Config{
		Iface:      cfg.WGIface,
		ServerPub:  cfg.WGServerPub,
		Endpoint:   cfg.WGEndpoint,
		DNS:        cfg.WGDNS,
		AllowedIPs: cfg.WGAllowedIPs,
		SubnetCIDR: cfg.WGSubnet,
	})

	stripeH := stripe.NewHandler(stripe.Config{
		WebhookSecret:    cfg.StripeWebhookSecret,
		PriceBasicMonth:  cfg.PriceBasicMonth,
		PriceBasicYear:   cfg.PriceBasicYear,
		PriceProMonth:    cfg.PriceProMonth,
		PriceProYear:     cfg.PriceProYear,
		BasicDeviceLimit: 3,
		ProDeviceLimit:   10,
	}, db)

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", httpx.Health)
	mux.HandleFunc("/v1/webhook/stripe", stripeH.Webhook)
	mux.HandleFunc("/v1/device", httpx.NewDeviceHandler(db, wgc).ServeHTTP)
	mux.HandleFunc("/v1/account", httpx.NewAccountHandler(db).ServeHTTP)

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           httpx.Middleware(mux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	go func() {
		log.Printf("cloakvpn-api listening on %s", cfg.Listen)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("http: %v", err)
		}
	}()

	<-ctx.Done()
	log.Printf("shutting down…")
	shCtx, shCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shCancel()
	_ = srv.Shutdown(shCtx)
}

type config struct {
	Listen              string
	DBPath              string
	StripeWebhookSecret string
	PriceBasicMonth     string
	PriceBasicYear      string
	PriceProMonth       string
	PriceProYear        string

	WGIface      string
	WGServerPub  string
	WGEndpoint   string
	WGDNS        string
	WGAllowedIPs string
	WGSubnet     string
}

func loadConfig() config {
	return config{
		Listen:              envOr("LISTEN_ADDR", "127.0.0.1:8080"),
		DBPath:              envOr("DB_PATH", "/var/lib/cloakvpn/cloakvpn.db"),
		StripeWebhookSecret: mustEnv("STRIPE_WEBHOOK_SECRET"),
		PriceBasicMonth:     mustEnv("STRIPE_PRICE_BASIC_MONTH"),
		PriceBasicYear:      mustEnv("STRIPE_PRICE_BASIC_YEAR"),
		PriceProMonth:       mustEnv("STRIPE_PRICE_PRO_MONTH"),
		PriceProYear:        mustEnv("STRIPE_PRICE_PRO_YEAR"),

		WGIface:      envOr("WG_IFACE", "wg0"),
		WGServerPub:  mustEnv("WG_SERVER_PUB"),
		WGEndpoint:   mustEnv("WG_ENDPOINT"), // e.g. fi1.cloakvpn.ai:51820
		WGDNS:        envOr("WG_DNS", "10.99.0.1"),
		WGAllowedIPs: envOr("WG_ALLOWED_IPS", "0.0.0.0/0, ::/0"),
		WGSubnet:     envOr("WG_SUBNET", "10.99.0.0/24"),
	}
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
		log.Fatalf("missing required env var %s", k)
	}
	return v
}
