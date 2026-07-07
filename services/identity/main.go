// Command identity is the identity service. It owns identity.users and
// resolves an OIDC subject to a user (auth.md §5.1 step 1) via the internal,
// in-cluster GET /internal/users/by-sub/{sub} — never exposed via the
// gateway. It also exposes the client-facing profile surface
// (GET/PATCH /v1/profile, FR-ONB-1, #25), mounted behind the gateway.
// Wiring follows services/servicetemplate/example/main.go.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"

	"github.com/TiagoJVO/beekeepingit/services/identity/api"
	"github.com/TiagoJVO/beekeepingit/services/identity/store"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/config"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/health"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/otelboot"
	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
)

func main() {
	if err := run(context.Background()); err != nil {
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

	if err := dbaccess.Migrate(ctx, cfg.DB.DSN(), store.MigrationsFS()); err != nil {
		return fmt.Errorf("migrate db: %w", err)
	}
	pool, err := dbaccess.Connect(ctx, cfg.DB)
	if err != nil {
		return fmt.Errorf("connect db: %w", err)
	}
	defer pool.Close()

	// Dev/CI-only: seed the test principal login resolves to (§4.5). Never
	// set in production, where EPIC-01 onboarding creates real users.
	if os.Getenv("SEED_DEV_DATA") == "true" {
		if err := store.Seed(ctx, pool); err != nil {
			return fmt.Errorf("seed dev data: %w", err)
		}
		logger.Info("seeded dev identity data")
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
	// Client-facing profile surface (FR-ONB-1, #25): authn only, no org
	// resolver — a brand-new user has no membership yet (see api/profile.go).
	srv.Mount("/v1", authnMW(api.PublicRouter(pool)))

	return srv.Run(ctx)
}
