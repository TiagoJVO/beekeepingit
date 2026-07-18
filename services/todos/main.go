// Command todos is the owning service of todo records (#50, EPIC-05 M5,
// FR-TD-1, FR-TEN-2, FR-HIS-1). It owns the `todos.todos`,
// `todos.sync_conflict_log` and `todos.audit_log` tables: the client-facing
// REST create/edit/complete/reopen/delete routes (api/write.go) and the
// internal sync validate/apply endpoints (api/sync.go) the write-back
// coordinator (services/sync) calls so an offline todo change reconciles on
// sync (FR-OF-1). Both write paths verify a client-supplied assignee_id
// belongs to an ACTIVE member of the caller's organization via the
// organizations service itself (api/members_client.go) before writing
// anything — todos has no database access to the organizations schema
// (ownership rule 1). Apiary association (#51) and list/filter UI (#53) are
// explicitly out of scope. Wiring follows services/activities/main.go
// (itself following services/servicetemplate/example/main.go).
package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/config"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/health"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/otelboot"
	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
	"github.com/TiagoJVO/beekeepingit/services/todos/api"
	"github.com/TiagoJVO/beekeepingit/services/todos/store"
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
	if identityURL == "" || organizationsURL == "" {
		return fmt.Errorf("config: INTERNAL_IDENTITY_URL and INTERNAL_ORGANIZATIONS_URL are required")
	}
	memberVerifier, err := api.NewMemberVerifier(organizationsURL, nil)
	if err != nil {
		return fmt.Errorf("build member verifier: %w", err)
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
	// Todos are shared by both membership roles (FR-TEN-2: "shared across
	// all org members"; D-23: assignment is not an access boundary) — no
	// admin-only todo operation exists in v1, mirroring activities/main.go's
	// own rationale for keeping RequireRole as real enforcement, not a no-op.
	roleMW := authn.RequireRole("admin", "user")
	scoped := func(h http.Handler) http.Handler { return authnMW(orgMW(roleMW(h))) }

	checks := health.NewRegistry()
	checks.Register("db", func(ctx context.Context) error { return pool.Ping(ctx) })

	srv, err := servicetemplate.New(cfg, providers, logger, checks)
	if err != nil {
		return fmt.Errorf("build server: %w", err)
	}
	srv.Mount("/v1/todos", scoped(api.Router(pool, memberVerifier)))
	srv.Mount("/internal/sync", scoped(api.InternalSyncRouter(pool, memberVerifier)))

	return srv.Run(ctx)
}
