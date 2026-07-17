// Command sync is the thin, stateless write-back service of the walking
// skeleton (walking-skeleton.md §4.3). It hosts the two client-facing sync
// endpoints — GET /v1/sync/token (mints the short-TTL org-scoped PowerSync
// token) and POST /v1/sync/batch (the write-back coordinator) — plus the
// internal JWKS PowerSync validates the token against. It owns no domain data
// and holds no schema credentials, so unlike the other services it needs no
// database; it builds its server config directly rather than via config.Load
// (which requires DB settings).
package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/config"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/health"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/otelboot"
	"github.com/TiagoJVO/beekeepingit/services/sync/api"
	"github.com/TiagoJVO/beekeepingit/services/sync/token"
)

func main() {
	if err := run(context.Background()); err != nil {
		slog.Error("fatal", slog.Any("error", err))
		os.Exit(1)
	}
}

// run wires the sync service together and blocks serving it. Each stage of
// setup (observability, token minting, the write-back coordinator, the
// authn/org-resolver chain, route mounting) is a small named helper below so
// this stays a flat, skimmable assembly list.
func run(ctx context.Context) error {
	e, err := loadEnv()
	if err != nil {
		return err
	}

	providers, cfg, logger, err := setupObservability(ctx, e)
	if err != nil {
		return err
	}

	minter, err := buildTokenMinter(e, logger)
	if err != nil {
		return err
	}

	coord, err := api.NewCoordinator(e.apiariesURL, e.activitiesURL)
	if err != nil {
		return fmt.Errorf("build coordinator: %w", err)
	}

	syncMW, err := buildSyncAuthnMiddleware(ctx, e)
	if err != nil {
		return err
	}

	srv, err := servicetemplate.New(cfg, providers, logger, health.NewRegistry())
	if err != nil {
		return fmt.Errorf("build server: %w", err)
	}
	mountRoutes(srv, minter, coord, syncMW)

	return srv.Run(ctx)
}

// setupObservability bootstraps OTel and builds the service's config/logger,
// installing the logger as slog's default so package-level slog.* calls
// elsewhere (e.g. the coordinator's upstream-failure logging) use it.
func setupObservability(ctx context.Context, e env) (*otelboot.Providers, config.Config, *slog.Logger, error) {
	providers, err := otelboot.Bootstrap(ctx, otelboot.Config{
		ServiceName:       e.serviceName,
		ServiceNamespace:  "beekeepingit",
		CollectorEndpoint: e.otelEndpoint,
		Insecure:          true,
	})
	if err != nil {
		return nil, config.Config{}, nil, fmt.Errorf("bootstrap otel: %w", err)
	}

	cfg := config.Config{ServiceName: e.serviceName, HTTPAddr: e.httpAddr, LogLevel: e.logLevel}
	logger := logging.NewLogger(cfg, providers.LoggerProvider)
	slog.SetDefault(logger)
	return providers, cfg, logger, nil
}

// buildTokenMinter loads (or, dev/CI-only, generates) the signing key and
// builds the sync-token Minter.
func buildTokenMinter(e env, logger *slog.Logger) (*token.Minter, error) {
	priv, generated, err := token.LoadOrGenerateKey(e.tokenPrivateKey)
	if err != nil {
		return nil, fmt.Errorf("load sync-token key: %w", err)
	}
	if generated {
		logger.Warn("sync-token signing key generated in-process (dev/CI only) — set SYNC_TOKEN_PRIVATE_KEY in production so tokens survive restarts")
	}
	minter, err := token.NewMinter(priv, e.tokenIssuer, e.tokenAudience, e.tokenTTL)
	if err != nil {
		return nil, fmt.Errorf("build token minter: %w", err)
	}
	return minter, nil
}

// buildSyncAuthnMiddleware composes the OIDC authn + org-resolver chain the
// client-facing sync endpoints are mounted behind.
func buildSyncAuthnMiddleware(ctx context.Context, e env) (func(http.Handler) http.Handler, error) {
	authnMW, err := authn.NewMiddleware(ctx, authn.Config{
		IssuerURL:    e.oidcIssuerURL,
		Audience:     e.oidcAudience,
		DiscoveryURL: e.oidcDiscoveryURL,
	})
	if err != nil {
		return nil, fmt.Errorf("build authn middleware: %w", err)
	}
	orgMW, err := authn.NewOrgResolver(authn.ResolveConfig{
		IdentityBaseURL:      e.identityURL,
		OrganizationsBaseURL: e.organizationsURL,
	})
	if err != nil {
		return nil, fmt.Errorf("build org resolver: %w", err)
	}
	return func(next http.Handler) http.Handler { return authnMW(orgMW(next)) }, nil
}

// mountRoutes wires the sync service's HTTP surface onto srv's router.
func mountRoutes(srv *servicetemplate.Server, minter *token.Minter, coord *api.Coordinator, syncMW func(http.Handler) http.Handler) {
	// Client-facing sync endpoints: OIDC-authenticated + org-resolved.
	srv.Router().Group(func(r chi.Router) {
		r.Use(syncMW)
		r.Get("/v1/sync/token", api.TokenHandler(minter))
		r.Post("/v1/sync/batch", api.BatchHandler(coord))
	})
	// Internal JWKS for PowerSync — a public key set, unauthenticated.
	srv.Router().Get("/internal/sync/jwks.json", api.JWKSHandler(minter))
}

type env struct {
	serviceName      string
	httpAddr         string
	logLevel         slog.Level
	otelEndpoint     string
	oidcIssuerURL    string
	oidcAudience     string
	oidcDiscoveryURL string
	identityURL      string
	organizationsURL string
	apiariesURL      string
	activitiesURL    string
	tokenIssuer      string
	tokenAudience    string
	tokenTTL         time.Duration
	tokenPrivateKey  string
}

func loadEnv() (env, error) {
	var missing []string
	req := func(k string) string {
		v := os.Getenv(k)
		if v == "" {
			missing = append(missing, k)
		}
		return v
	}
	def := func(k, d string) string {
		if v := os.Getenv(k); v != "" {
			return v
		}
		return d
	}

	e := env{
		serviceName:      req("SERVICE_NAME"),
		httpAddr:         def("HTTP_ADDR", ":8080"),
		logLevel:         parseLevel(def("LOG_LEVEL", "info")),
		otelEndpoint:     def("OTEL_EXPORTER_OTLP_ENDPOINT", "localhost:4317"),
		oidcIssuerURL:    req("OIDC_ISSUER_URL"),
		oidcAudience:     req("OIDC_AUDIENCE"),
		oidcDiscoveryURL: os.Getenv("OIDC_DISCOVERY_URL"),
		identityURL:      req("INTERNAL_IDENTITY_URL"),
		organizationsURL: req("INTERNAL_ORGANIZATIONS_URL"),
		apiariesURL:      req("INTERNAL_APIARIES_URL"),
		activitiesURL:    req("INTERNAL_ACTIVITIES_URL"),
		tokenIssuer:      req("SYNC_TOKEN_ISSUER"),
		tokenAudience:    req("SYNC_TOKEN_AUDIENCE"),
		tokenPrivateKey:  os.Getenv("SYNC_TOKEN_PRIVATE_KEY"),
	}
	e.tokenTTL = parseTTL(def("SYNC_TOKEN_TTL", "5m"))

	if len(missing) > 0 {
		return env{}, fmt.Errorf("config: missing required env: %s", strings.Join(missing, ", "))
	}
	return e, nil
}

func parseLevel(s string) slog.Level {
	switch strings.ToLower(s) {
	case "debug":
		return slog.LevelDebug
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}

func parseTTL(s string) time.Duration {
	d, err := time.ParseDuration(s)
	if err != nil || d <= 0 {
		return 5 * time.Minute
	}
	return d
}
