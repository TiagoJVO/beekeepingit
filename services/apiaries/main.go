// Command apiaries is the owning service of the walking skeleton's trivial
// record. It exposes the client-facing read surface (GET /v1/apiaries[/{id}])
// and the internal sync validate/apply endpoints the write-back coordinator
// calls (walking-skeleton.md §4.4/§5, sync.md §5.2). Both surfaces run behind
// Keycloak authn + the org-resolver + authn.RequireRole (#28) so every
// request is org-scoped and carries a resolved membership role. Online REST
// write handlers are EPIC-02 (#31), not the skeleton. Wiring follows
// services/servicetemplate/example/main.go.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"

	"github.com/TiagoJVO/beekeepingit/services/apiaries/api"
	"github.com/TiagoJVO/beekeepingit/services/apiaries/store"
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
	if identityURL == "" || organizationsURL == "" {
		return fmt.Errorf("config: INTERNAL_IDENTITY_URL and INTERNAL_ORGANIZATIONS_URL are required")
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
	// Apiary CRUD is shared by both membership roles (auth.md §5.3 — no
	// admin-only apiary operation exists in v1); RequireRole here still adds
	// real enforcement, not a no-op: it's the explicit, auditable "role must
	// have resolved to a known value" gate (#28 AC), closing the latent gap
	// where a wiring regression leaving Role unresolved would otherwise pass
	// through unnoticed (requireOrg only ever checked OrganizationID).
	roleMW := authn.RequireRole("admin", "user")
	scoped := func(h http.Handler) http.Handler { return authnMW(orgMW(roleMW(h))) }

	checks := health.NewRegistry()
	checks.Register("db", func(ctx context.Context) error { return pool.Ping(ctx) })

	srv, err := servicetemplate.New(cfg, providers, logger, checks)
	if err != nil {
		return fmt.Errorf("build server: %w", err)
	}
	srv.Mount("/v1/apiaries", scoped(api.ReadRouter(pool)))
	srv.Mount("/internal/sync", scoped(api.InternalSyncRouter(pool)))

	return srv.Run(ctx)
}
