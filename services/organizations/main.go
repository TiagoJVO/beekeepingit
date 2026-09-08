// Command organizations owns organizations, memberships and invitations.
// Besides the internal, in-cluster GET /internal/memberships/active (auth.md
// §5.1 steps 2–3; never exposed via the gateway), it exposes the
// client-facing organization surface: create/read (POST /organizations,
// GET /organizations/me[/{orgId}], FR-ONB-2/FR-TEN-2/NFR-ROL-1, #26) and
// admin-only membership + email invitations (GET .../members,
// GET/POST .../invitations, DELETE .../invitations/{id}, FR-ONB-3, D-3, #27),
// mounted behind the gateway. Wiring follows
// services/servicetemplate/example/main.go.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"strings"

	"github.com/TiagoJVO/beekeepingit/services/organizations/api"
	"github.com/TiagoJVO/beekeepingit/services/organizations/store"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/config"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/health"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/otelboot"
	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
	"github.com/TiagoJVO/beekeepingit/services/shared/mail"
)

func main() {
	ctx := context.Background()

	// "migrate" runs the deploy-time migration admin process and exits; with
	// no argument the binary serves (#541, 12-factor XII). DDL never happens
	// on the serving path any more — see migrate.go for why.
	if len(os.Args) > 1 && os.Args[1] == "migrate" {
		if err := runMigrate(ctx); err != nil {
			slog.Error("fatal", slog.Any("error", err))
			os.Exit(1)
		}
		return
	}

	if err := run(ctx); err != nil {
		slog.Error("fatal", slog.Any("error", err))
		os.Exit(1)
	}
}

func run(ctx context.Context) error {
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}

	providers, err := otelboot.Bootstrap(ctx, otelboot.Config{
		ServiceName:       cfg.ServiceName,
		ServiceNamespace:  "beekeepingit",
		CollectorEndpoint: cfg.OTelEndpoint,
		Insecure:          true,
	})
	if err != nil {
		return fmt.Errorf("bootstrap otel: %w", err)
	}

	logger := logging.NewLogger(cfg, providers.LoggerProvider)
	slog.SetDefault(logger)
	pool, err := dbaccess.Connect(ctx, cfg.DB)
	if err != nil {
		return fmt.Errorf("connect db: %w", err)
	}
	defer pool.Close()

	// Dev/CI-only: seed the org + active admin membership the resolve path
	// needs (§4.5). Never set in production (EPIC-01 onboarding replaces it).
	if os.Getenv("SEED_DEV_DATA") == "true" {
		if err := store.Seed(ctx, pool); err != nil {
			return fmt.Errorf("seed dev data: %w", err)
		}
		logger.Info("seeded dev organizations data")
	}

	identityURL := os.Getenv("INTERNAL_IDENTITY_URL")
	if identityURL == "" {
		return fmt.Errorf("config: INTERNAL_IDENTITY_URL is required")
	}

	authnMW, err := authn.NewMiddleware(ctx, authn.Config{
		IssuerURL:    cfg.OIDCIssuerURL,
		Audience:     cfg.OIDCAudience,
		DiscoveryURL: cfg.OIDCDiscoveryURL,
	})
	if err != nil {
		return fmt.Errorf("build authn middleware: %w", err)
	}

	checks := health.NewRegistry()
	checks.Register("db", func(ctx context.Context) error { return pool.Ping(ctx) })

	srv, err := servicetemplate.New(cfg, providers, logger, checks)
	if err != nil {
		return fmt.Errorf("build server: %w", err)
	}
	srv.Mount("/internal", authnMW(api.InternalRouter(pool)))
	// Client-facing organization surface (FR-ONB-2/FR-TEN-2/NFR-ROL-1, #26):
	// authn only, no org resolver — see api/organizations.go's package doc
	// for why (a brand-new caller must reach POST /organizations, and the
	// GET routes resolve their own org directly rather than looping back
	// into this same service over HTTP).
	userResolver := api.NewHTTPUserResolver(identityURL, nil)
	srv.Mount("/v1", authnMW(api.PublicRouter(pool, userResolver, mailOptions(logger)...)))

	return srv.Run(ctx)
}

// mailOptions wires the outbound invitation email (#641, FR-ONB-3) when the
// environment provides both an SMTP relay and the app's browser-facing base
// URL, and wires nothing when it does not.
//
// A missing or broken mail configuration is deliberately NOT fatal. This
// service owns organizations, memberships and the authorization resolve path
// every other service depends on; refusing to start because no relay is
// provisioned yet would take the platform down over a feature that degrades
// perfectly well on its own -- each invitation simply records delivery_status
// "failed" with reason "not_configured", which the admin can see and retry
// once the relay lands (issue #417's deploy-time job). Logged loudly at
// startup so it is never a silent surprise.
func mailOptions(logger *slog.Logger) []api.RouterOption {
	appBaseURL, err := validatedAppBaseURL(os.Getenv("APP_BASE_URL"))
	if err != nil {
		logger.Warn("invitation email disabled: APP_BASE_URL is unusable", slog.Any("error", err))
		return nil
	}

	cfg, err := mail.LoadConfig()
	if err != nil {
		logger.Warn("invitation email disabled: no usable SMTP configuration", slog.Any("error", err))
		return nil
	}
	sender, err := mail.New(cfg)
	if err != nil {
		logger.Warn("invitation email disabled: SMTP configuration rejected", slog.Any("error", err))
		return nil
	}

	logger.Info("invitation email enabled", slog.String("smtp_host", cfg.Host), slog.Int("smtp_port", cfg.Port))
	return []api.RouterOption{api.WithMailer(sender, appBaseURL)}
}

// validatedAppBaseURL checks the one piece of configuration that ends up
// INSIDE an email as a clickable link (#641). It is validated here, at
// startup, rather than trusted at send time, because a malformed value would
// be a phishing vector delivered under this product's name to addresses an
// admin chose.
//
// Requirements: absolute, http or https, a real host, and no query or
// fragment -- the sign-up path is appended by the service, so anything else in
// the value is either a mistake or an attempt to smuggle a redirect target.
func validatedAppBaseURL(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", fmt.Errorf("config: APP_BASE_URL is not set")
	}
	u, err := url.Parse(raw)
	if err != nil {
		return "", fmt.Errorf("config: APP_BASE_URL is not a valid URL: %w", err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return "", fmt.Errorf("config: APP_BASE_URL must be http or https, got %q", u.Scheme)
	}
	if u.Host == "" {
		return "", fmt.Errorf("config: APP_BASE_URL has no host")
	}
	if u.RawQuery != "" || u.Fragment != "" {
		return "", fmt.Errorf("config: APP_BASE_URL must not carry a query or fragment")
	}
	return strings.TrimSuffix(raw, "/"), nil
}
