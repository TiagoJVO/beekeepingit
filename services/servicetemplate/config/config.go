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
	"strings"

	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
)

// Config is the environment-driven configuration every service built on the
// template needs.
type Config struct {
	ServiceName      string
	HTTPAddr         string
	LogLevel         slog.Level
	OTelEndpoint     string
	OIDCIssuerURL    string
	OIDCAudience     string
	OIDCDiscoveryURL string
	DB               dbaccess.Config
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
		ServiceName:      req("SERVICE_NAME"),
		HTTPAddr:         envDefault("HTTP_ADDR", ":8080"),
		OTelEndpoint:     envDefault("OTEL_EXPORTER_OTLP_ENDPOINT", "localhost:4317"),
		OIDCIssuerURL:    req("OIDC_ISSUER_URL"),
		OIDCAudience:     req("OIDC_AUDIENCE"),
		OIDCDiscoveryURL: os.Getenv("OIDC_DISCOVERY_URL"),
		DB: dbaccess.Config{
			Host:       req("DB_HOST"),
			Port:       envDefault("DB_PORT", "5432"),
			User:       req("DB_USER"),
			Password:   os.Getenv("DB_PASSWORD"),
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

	if len(errs) > 0 {
		return Config{}, errors.Join(errs...)
	}
	return cfg, nil
}

func envDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
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
