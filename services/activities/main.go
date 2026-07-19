// Command activities is the owning service of activity records (#38, EPIC-03
// M3, FR-AC-1..6, FR-TEN-2). It owns the `activities.activities`,
// `activities.sync_conflict_log` and `activities.audit_log` tables and the
// per-type JSONB-attribute model + server-side validation (api/types.go).
//
// #38's scope was deliberately the DATA MODEL, not the CRUD API — that
// thin internal validate endpoint (api/validate.go) proved the tenancy +
// validation wiring end-to-end. #39 extends this same wiring (authn +
// org-resolver + RequireRole, following services/apiaries/main.go) with the
// real write paths: the client-facing REST create route (api/write.go,
// POST /v1/activities) and the internal sync validate/apply endpoints
// (api/sync.go) the write-back coordinator (services/sync) calls so an
// offline-created activity reconciles on sync (FR-OF-1). Both write paths
// verify a client-supplied apiary_id belongs to the caller's organization
// via the apiaries service itself (api/apiaries_client.go) before writing
// anything — activities has no database access to the apiaries schema
// (ownership rule 1). Edit/delete/list are later EPIC-03 stories.
//
// #46 (EPIC-04 M4) adds the same ownership guard for the optional
// journey_id field: both write paths verify it against the journeys service
// itself (api/journeys_client.go) before create — journey_id, once set, is
// otherwise immutable (never touched by edit).
// Wiring follows services/servicetemplate/example/main.go.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"

	"github.com/TiagoJVO/beekeepingit/services/activities/api"
	"github.com/TiagoJVO/beekeepingit/services/activities/store"
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
	journeysURL := os.Getenv("INTERNAL_JOURNEYS_URL")
	if identityURL == "" || organizationsURL == "" || apiariesURL == "" || journeysURL == "" {
		return fmt.Errorf("config: INTERNAL_IDENTITY_URL, INTERNAL_ORGANIZATIONS_URL, INTERNAL_APIARIES_URL and INTERNAL_JOURNEYS_URL are required")
	}
	apiaryVerifier, err := api.NewApiaryVerifier(apiariesURL, nil)
	if err != nil {
		return fmt.Errorf("build apiary verifier: %w", err)
	}
	// journeyVerifier (#46) closes the cross-org journey_id IDOR gap the
	// same way apiaryVerifier already closes it for apiary_id — see
	// api/journeys_client.go's package doc for the full rationale.
	journeyVerifier, err := api.NewJourneyVerifier(journeysURL, nil)
	if err != nil {
		return fmt.Errorf("build journey verifier: %w", err)
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
	// Activity validation is shared by both membership roles, same as
	// apiaries' CRUD (auth.md §5.3 — no admin-only activity operation exists
	// in v1); RequireRole here still adds real enforcement, not a no-op,
	// mirroring apiaries/main.go's own rationale for keeping it.
	roleMW := authn.RequireRole("admin", "user")
	scoped := func(h http.Handler) http.Handler { return authnMW(orgMW(roleMW(h))) }

	checks := health.NewRegistry()
	checks.Register("db", func(ctx context.Context) error { return pool.Ping(ctx) })

	srv, err := servicetemplate.New(cfg, providers, logger, checks)
	if err != nil {
		return fmt.Errorf("build server: %w", err)
	}
	srv.Mount("/internal/activities", scoped(api.InternalValidateRouter()))
	srv.Mount("/v1/activities", scoped(api.Router(pool, apiaryVerifier, journeyVerifier)))
	srv.Mount("/internal/sync", scoped(api.InternalSyncRouter(pool, apiaryVerifier, journeyVerifier)))

	return srv.Run(ctx)
}
