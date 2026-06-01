// Cloak VPN API — Phase 0 scaffold.
//
// Responsibilities:
//   - Serve Stripe webhooks (checkout.session.completed, customer.subscription.*)
//     and maintain an account → tier → device-limit record.
//   - Issue device configs (WireGuard + Rosenpass keys) for paying customers,
//     enforcing the Basic/Pro device cap.
//   - Stay simple enough to run on the same Hetzner CX22 as wg + rosenpass.
//
// No-account model: a subscription is identified by a random account number
// (see internal/account); the apps authenticate /v1/device and /v1/account
// with it. See docs/BILLING_INTEGRATION.md.
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
	"strconv"
	"syscall"
	"time"

	"github.com/cloakvpn/api/internal/appleiap"
	httpx "github.com/cloakvpn/api/internal/http"
	"github.com/cloakvpn/api/internal/regions"
	"github.com/cloakvpn/api/internal/store"
	"github.com/cloakvpn/api/internal/stripe"
	stripego "github.com/stripe/stripe-go/v79"
)

func main() {
	cfg := loadConfig()

	// The Stripe SDK reads this package-global key for all API calls
	// (writing the account number to customer metadata, reading it back).
	stripego.Key = cfg.StripeSecretKey

	db, err := store.Open(cfg.DBPath)
	if err != nil {
		log.Fatalf("store open: %v", err)
	}
	defer db.Close()

	regs, err := regions.Load(cfg.RegionsConfig)
	if err != nil {
		log.Fatalf("regions config: %v", err)
	}
	rc := regions.NewClient(cfg.RegionInternalSecret)

	stripeH := stripe.NewHandler(stripe.Config{
		WebhookSecret:       cfg.StripeWebhookSecret,
		PriceBasicMonth:     cfg.PriceBasicMonth,
		PriceBasicYear:      cfg.PriceBasicYear,
		PriceProMonth:       cfg.PriceProMonth,
		PriceProYear:        cfg.PriceProYear,
		BasicDeviceLimit:    cfg.BasicDeviceLimit,
		ProDeviceLimit:      cfg.ProDeviceLimit,
		AccountNumberSecret: cfg.AccountNumberSecret,
	}, db)

	iapH := appleiap.NewHandler(appleiap.Config{
		BundleID:            cfg.AppleBundleID,
		ProductBasicMonthly: cfg.AppleProductBasicMonthly,
		ProductBasicYearly:  cfg.AppleProductBasicYearly,
		ProductProMonthly:   cfg.AppleProductProMonthly,
		ProductProYearly:    cfg.AppleProductProYearly,
		BasicDeviceLimit:    cfg.BasicDeviceLimit,
		ProDeviceLimit:      cfg.ProDeviceLimit,
		AccountNumberSecret: cfg.AccountNumberSecret,
	}, db)

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", httpx.Health)
	mux.HandleFunc("/v1/webhook/stripe", stripeH.Webhook)
	mux.HandleFunc("/v1/iap", iapH.Verify)
	mux.HandleFunc("/v1/iap/notifications", iapH.Notifications)
	mux.HandleFunc("/v1/device", httpx.NewDeviceHandler(db, regs, rc,
		cfg.AccountNumberSecret, cfg.DefaultRegion, cfg.WGSubnet).ServeHTTP)
	mux.HandleFunc("/v1/account", httpx.NewAccountHandler(db, cfg.AccountNumberSecret).ServeHTTP)
	mux.HandleFunc("/v1/account-number", httpx.NewAccountNumberHandler(db).ServeHTTP)

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
	StripeSecretKey     string
	AccountNumberSecret string
	PriceBasicMonth     string
	PriceBasicYear      string
	PriceProMonth       string
	PriceProYear        string

	BasicDeviceLimit int
	ProDeviceLimit   int

	// Apple IAP — product IDs must match the App Store Connect subscriptions.
	AppleBundleID            string
	AppleProductBasicMonthly string
	AppleProductBasicYearly  string
	AppleProductProMonthly   string
	AppleProductProYearly    string

	WGSubnet             string
	RegionsConfig        string
	RegionInternalSecret string
	DefaultRegion        string
}

func loadConfig() config {
	return config{
		Listen:              envOr("LISTEN_ADDR", "127.0.0.1:8080"),
		DBPath:              envOr("DB_PATH", "/var/lib/cloakvpn/cloakvpn.db"),
		StripeWebhookSecret: mustEnv("STRIPE_WEBHOOK_SECRET"),
		StripeSecretKey:     mustEnv("STRIPE_SECRET_KEY"),
		AccountNumberSecret: mustEnv("ACCOUNT_NUMBER_SECRET"),
		PriceBasicMonth:     mustEnv("STRIPE_PRICE_BASIC_MONTH"),
		PriceBasicYear:      mustEnv("STRIPE_PRICE_BASIC_YEAR"),
		PriceProMonth:       mustEnv("STRIPE_PRICE_PRO_MONTH"),
		PriceProYear:        mustEnv("STRIPE_PRICE_PRO_YEAR"),

		BasicDeviceLimit: envInt("BASIC_DEVICE_LIMIT", 3),
		ProDeviceLimit:   envInt("PRO_DEVICE_LIMIT", 10),

		// Optional (defaults match the planned App Store Connect product IDs)
		// so deploying this binary needs no new env to keep running.
		AppleBundleID:            envOr("APPLE_BUNDLE_ID", "ai.cloakvpn.CloakVPN"),
		AppleProductBasicMonthly: envOr("APPLE_PRODUCT_BASIC_MONTHLY", "ai.cloakvpn.CloakVPN.basic.monthly"),
		AppleProductBasicYearly:  envOr("APPLE_PRODUCT_BASIC_YEARLY", "ai.cloakvpn.CloakVPN.basic.yearly"),
		AppleProductProMonthly:   envOr("APPLE_PRODUCT_PRO_MONTHLY", "ai.cloakvpn.CloakVPN.pro.monthly"),
		AppleProductProYearly:    envOr("APPLE_PRODUCT_PRO_YEARLY", "ai.cloakvpn.CloakVPN.pro.yearly"),

		WGSubnet:             envOr("WG_SUBNET", "10.99.0.0/24"),
		RegionsConfig:        envOr("REGIONS_CONFIG", "/etc/cloakvpn/regions.json"),
		RegionInternalSecret: mustEnv("REGION_INTERNAL_SECRET"),
		DefaultRegion:        envOr("DEFAULT_REGION", "us-west-1"),
	}
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// envInt reads a positive integer env var, falling back to def when the
// variable is unset or not a positive integer.
func envInt(k string, def int) int {
	v := os.Getenv(k)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		log.Printf("env %s=%q is not a positive integer; using default %d", k, v, def)
		return def
	}
	return n
}

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		log.Fatalf("missing required env var %s", k)
	}
	return v
}
