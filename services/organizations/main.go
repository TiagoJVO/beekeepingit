// Command organizations is the minimal organizations service for the M0
// walking skeleton: it owns organizations + memberships and resolves a user
// to its active membership — organization_id + role (auth.md §5.1 steps 2–3).
// Its only route is the internal, in-cluster GET /internal/memberships/active;
// it is never exposed via the gateway. Wiring follows
// services/servicetemplate/example/main.go.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"

	"github.com/TiagoJVO/beekeepingit/services/organizations/api"
	"github.com/TiagoJVO/beekeepingit/services/organizations/store"
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

	// Dev/CI-only: seed the org + active admin membership the resolve path
	// needs (§4.5). Never set in production (EPIC-01 onboarding replaces it).
	if os.Getenv("SEED_DEV_DATA") == "true" {
		if err := store.Seed(ctx, pool); err != nil {
			return fmt.Errorf("seed dev data: %w", err)
		}
		logger.Info("seeded dev organizations data")
	}

	authnMW, err := authn.NewMiddleware(ctx, authn.Config{IssuerURL: cfg.OIDCIssuerURL, Audience: cfg.OIDCAudience})
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

	return srv.Run(ctx)
}
