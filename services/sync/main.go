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

func run(ctx context.Context) error {
	env, err := loadEnv()
	if err != nil {
		return err
	}

	providers, err := otelboot.Bootstrap(ctx, otelboot.Config{
		ServiceName:       env.serviceName,
		ServiceNamespace:  "beekeepingit",
		CollectorEndpoint: env.otelEndpoint,
		Insecure:          true,
	})
	if err != nil {
		return fmt.Errorf("bootstrap otel: %w", err)
	}

	cfg := config.Config{ServiceName: env.serviceName, HTTPAddr: env.httpAddr, LogLevel: env.logLevel}
	logger := logging.NewLogger(cfg, providers.LoggerProvider)
	slog.SetDefault(logger)

	priv, generated, err := token.LoadOrGenerateKey(env.tokenPrivateKey)
	if err != nil {
		return fmt.Errorf("load sync-token key: %w", err)
	}
	if generated {
		logger.Warn("sync-token signing key generated in-process (dev/CI only) — set SYNC_TOKEN_PRIVATE_KEY in production so tokens survive restarts")
	}
	minter, err := token.NewMinter(priv, env.tokenIssuer, env.tokenAudience, env.tokenTTL)
	if err != nil {
		return fmt.Errorf("build token minter: %w", err)
	}

	coord, err := api.NewCoordinator(env.apiariesURL)
	if err != nil {
		return fmt.Errorf("build coordinator: %w", err)
	}

	authnMW, err := authn.NewMiddleware(ctx, authn.Config{
		IssuerURL:    env.oidcIssuerURL,
		Audience:     env.oidcAudience,
		DiscoveryURL: env.oidcDiscoveryURL,
	})
	if err != nil {
		return fmt.Errorf("build authn middleware: %w", err)
	}
	orgMW, err := authn.NewOrgResolver(authn.ResolveConfig{
		IdentityBaseURL:      env.identityURL,
		OrganizationsBaseURL: env.organizationsURL,
	})
	if err != nil {
		return fmt.Errorf("build org resolver: %w", err)
	}

	srv, err := servicetemplate.New(cfg, providers, logger, health.NewRegistry())
	if err != nil {
		return fmt.Errorf("build server: %w", err)
	}

	// Client-facing sync endpoints: Keycloak-authenticated + org-resolved.
	srv.Router().Group(func(r chi.Router) {
		r.Use(func(next http.Handler) http.Handler { return authnMW(orgMW(next)) })
		r.Get("/v1/sync/token", api.TokenHandler(minter))
		r.Post("/v1/sync/batch", api.BatchHandler(coord))
	})
	// Internal JWKS for PowerSync — a public key set, unauthenticated.
	srv.Router().Get("/internal/sync/jwks.json", api.JWKSHandler(minter))

	return srv.Run(ctx)
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
