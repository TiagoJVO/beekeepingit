// Package config loads the shared service template's configuration from the
// environment: HTTP, logging, OTel export, JWT validation and DB access.
// Required values missing are aggregated into a single returned error
// instead of failing on the first one, per the template's fail-fast AC.
package config

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"strings"

	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
)

// Config is the environment-driven configuration every service built on the
// template needs.
type Config struct {
	ServiceName  string
	HTTPAddr     string
	LogLevel     slog.Level
	OTelEndpoint string
	// OTelInsecure controls whether the OTLP/gRPC exporters skip TLS when
	// talking to the collector (otelboot.Config.Insecure). Defaults to true
	// (no TLS), matching an in-cluster/local-dev collector; set
	// OTEL_INSECURE=false for a collector that requires TLS.
	OTelInsecure     bool
	OIDCIssuerURL    string
	OIDCAudience     string
	OIDCDiscoveryURL string
	// CORSAllowedOrigins is the exact-match allowlist of browser origins the
	// service answers cross-origin CORS for (the admin app's origin, #449).
	// Empty (the default) disables CORS — same-origin callers only. Set via
	// CORS_ALLOWED_ORIGINS as a comma-separated list.
	CORSAllowedOrigins []string
	DB                 dbaccess.Config
}

// Load reads Config from the process environment.
func Load() (Config, error) {
	var errs []error
	req := func(key string) string {
		v := os.Getenv(key)
		if v == "" {
			errs = append(errs, fmt.Errorf("config: %s is required", key))
		}
		return v
	}

	cfg := Config{
		ServiceName:        req("SERVICE_NAME"),
		HTTPAddr:           envDefault("HTTP_ADDR", ":8080"),
		OTelEndpoint:       envDefault("OTEL_EXPORTER_OTLP_ENDPOINT", "localhost:4317"),
		OIDCIssuerURL:      req("OIDC_ISSUER_URL"),
		OIDCAudience:       req("OIDC_AUDIENCE"),
		OIDCDiscoveryURL:   os.Getenv("OIDC_DISCOVERY_URL"),
		CORSAllowedOrigins: parseCSV(os.Getenv("CORS_ALLOWED_ORIGINS")),
		DB: dbaccess.Config{
			Host:       req("DB_HOST"),
			Port:       envDefault("DB_PORT", "5432"),
			User:       req("DB_USER"),
			Password:   req("DB_PASSWORD"),
			Database:   req("DB_NAME"),
			SSLMode:    envDefault("DB_SSLMODE", "require"),
			SearchPath: os.Getenv("DB_SEARCH_PATH"),
		},
	}

	level, err := parseLogLevel(envDefault("LOG_LEVEL", "info"))
	if err != nil {
		errs = append(errs, err)
	}
	cfg.LogLevel = level

	insecure, err := parseBool("OTEL_INSECURE", envDefault("OTEL_INSECURE", "true"))
	if err != nil {
		errs = append(errs, err)
	}
	cfg.OTelInsecure = insecure

	if len(errs) > 0 {
		return Config{}, errors.Join(errs...)
	}
	return cfg, nil
}

// LoadDB loads ONLY the database settings, for admin processes that talk to
// Postgres but serve no HTTP — specifically the deploy-time migrate job (#541,
// 12-factor XII). Load would reject those with "OIDC_ISSUER_URL is required",
// and handing a migration job OIDC credentials it never uses would be exactly
// the over-provisioning this split exists to remove: the migrate job runs with
// the DDL-capable migrator role, so it should carry the smallest possible
// surrounding configuration.
//
// Note DB_USER/DB_PASSWORD here are the MIGRATOR credential, not the service
// runtime one — the two now differ deliberately (see the migrate job template
// in charts/services), which is the whole point of #541's fix.
func LoadDB() (dbaccess.Config, error) {
	var errs []error
	req := func(key string) string {
		v := os.Getenv(key)
		if v == "" {
			errs = append(errs, fmt.Errorf("config: %s is required", key))
		}
		return v
	}

	cfg := dbaccess.Config{
		Host:       req("DB_HOST"),
		Port:       envDefault("DB_PORT", "5432"),
		User:       req("DB_USER"),
		Password:   req("DB_PASSWORD"),
		Database:   req("DB_NAME"),
		SSLMode:    envDefault("DB_SSLMODE", "require"),
		SearchPath: os.Getenv("DB_SEARCH_PATH"),
	}

	if len(errs) > 0 {
		return dbaccess.Config{}, errors.Join(errs...)
	}

	// Validate HERE, unlike Load. A serving process reaches dbaccess.Connect,
	// which validates on the way in; the migrate admin process calls Migrate
	// and exits, so without this its Config would never be validated at all.
	// SearchPath is the one that matters — it is concatenated into the DSN's
	// `options=-c search_path=` and an unvalidated value can inject further
	// connection options, which in this job would carry database-OWNER
	// privileges.
	if err := cfg.Validate(); err != nil {
		return dbaccess.Config{}, err
	}
	return cfg, nil
}

// parseCSV splits a comma-separated env value into a trimmed, empty-free slice.
// Returns nil for an empty/absent value so an unset CORS_ALLOWED_ORIGINS leaves
// CORS disabled rather than allowlisting an empty origin.
func parseCSV(s string) []string {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	var out []string
	for _, part := range strings.Split(s, ",") {
		if v := strings.TrimSpace(part); v != "" {
			out = append(out, v)
		}
	}
	return out
}

func envDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// parseBool parses s as a boolean for env var key, returning an error naming
// key (not just the raw value) so a misconfigured env var is easy to spot in
// the aggregated Load() error.
func parseBool(key, s string) (bool, error) {
	v, err := strconv.ParseBool(s)
	if err != nil {
		return false, fmt.Errorf("config: %s %q is not a valid boolean", key, s)
	}
	return v, nil
}

func parseLogLevel(s string) (slog.Level, error) {
	switch strings.ToLower(s) {
	case "debug":
		return slog.LevelDebug, nil
	case "info":
		return slog.LevelInfo, nil
	case "warn", "warning":
		return slog.LevelWarn, nil
	case "error":
		return slog.LevelError, nil
	default:
		return 0, fmt.Errorf("config: LOG_LEVEL %q is not one of debug/info/warn/error", s)
	}
}
