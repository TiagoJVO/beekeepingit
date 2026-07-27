// Command journeys is the owning service of journey records (#45, EPIC-04
// M4, FR-JO-4, FR-TEN-2, D-21). It owns the `journeys.journeys`,
// `journeys.journey_plan_items`, `journeys.sync_conflict_log` and
// `journeys.audit_log` tables and this service's own small
// main-activity-type/status registry (api/types.go).
//
// #45 ships the full CRUD surface in one story (unlike activities'/
// apiaries' own #38→#39 split): the client-facing REST routes
// (api/write.go, POST/PATCH/DELETE /v1/journeys[/{id}] — create, edit
// including the full plan-items replace, D-21's close transition, and
// delete) and the internal sync validate/apply endpoints (api/sync.go) the
// write-back coordinator (services/sync) calls so a journey created/edited
// offline reconciles on sync (FR-OF-1). Every write path that touches a
// journey's plan verifies each apiary_id belongs to the caller's
// organization via the apiaries service itself (api/apiaries_client.go)
// before writing anything — journeys has no database access to the apiaries
// schema (ownership rule 1), exactly like activities' own #39 carry-over of
// #38's review finding. Wiring follows services/servicetemplate/example/main.go
// and services/activities/main.go.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"

	"github.com/TiagoJVO/beekeepingit/services/journeys/api"
	"github.com/TiagoJVO/beekeepingit/services/journeys/store"
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

	identityURL := os.Getenv("INTERNAL_IDENTITY_URL")
	organizationsURL := os.Getenv("INTERNAL_ORGANIZATIONS_URL")
	apiariesURL := os.Getenv("INTERNAL_APIARIES_URL")
	if identityURL == "" || organizationsURL == "" || apiariesURL == "" {
		return fmt.Errorf("config: INTERNAL_IDENTITY_URL, INTERNAL_ORGANIZATIONS_URL and INTERNAL_APIARIES_URL are required")
	}
	apiaryVerifier, err := api.NewApiaryVerifier(apiariesURL, nil)
	if err != nil {
		return fmt.Errorf("build apiary verifier: %w", err)
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

	authnMW, err := authn.NewMiddleware(ctx, authn.Config{
		IssuerURL:    cfg.OIDCIssuerURL,
		Audience:     cfg.OIDCAudience,
		DiscoveryURL: cfg.OIDCDiscoveryURL,
	})
	if err != nil {
		return fmt.Errorf("build authn middleware: %w", err)
	}
	orgMW, err := authn.NewOrgResolver(authn.ResolveConfig{
		IdentityBaseURL:      identityURL,
		OrganizationsBaseURL: organizationsURL,
	})
	if err != nil {
		return fmt.Errorf("build org resolver: %w", err)
	}
	// Journey CRUD is shared by both membership roles, same as
	// activities'/apiaries' own CRUD (auth.md §5.3 — no admin-only journey
	// operation exists in v1); RequireRole here still adds real enforcement,
	// mirroring their own rationale for keeping it.
	roleMW := authn.RequireRole("admin", "user")
	scoped := func(h http.Handler) http.Handler { return authnMW(orgMW(roleMW(h))) }

	checks := health.NewRegistry()
	checks.Register("db", func(ctx context.Context) error { return pool.Ping(ctx) })

	srv, err := servicetemplate.New(cfg, providers, logger, checks)
	if err != nil {
		return fmt.Errorf("build server: %w", err)
	}
	srv.Mount("/v1/journeys", scoped(api.Router(pool, apiaryVerifier)))
	srv.Mount("/internal/sync", scoped(api.InternalSyncRouter(pool, apiaryVerifier)))

	return srv.Run(ctx)
}
