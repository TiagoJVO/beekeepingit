package config_test

import (
	"log/slog"
	"strings"
	"testing"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/config"
)

func setRequiredEnv(t *testing.T) {
	t.Helper()
	t.Setenv("SERVICE_NAME", "example")
	t.Setenv("OIDC_ISSUER_URL", "https://auth.example/application/o/beekeepingit/")
	t.Setenv("OIDC_AUDIENCE", "beekeepingit-example")
	t.Setenv("DB_HOST", "postgres")
	t.Setenv("DB_USER", "example_svc")
	t.Setenv("DB_NAME", "beekeepingit")
}

func TestLoad_AppliesDefaults(t *testing.T) {
	setRequiredEnv(t)

	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("Load() error = %v, want nil", err)
	}
	if cfg.HTTPAddr != ":8080" {
		t.Errorf("HTTPAddr = %q, want %q", cfg.HTTPAddr, ":8080")
	}
	if cfg.OTelEndpoint != "localhost:4317" {
		t.Errorf("OTelEndpoint = %q, want %q", cfg.OTelEndpoint, "localhost:4317")
	}
	if cfg.LogLevel != slog.LevelInfo {
		t.Errorf("LogLevel = %v, want %v", cfg.LogLevel, slog.LevelInfo)
	}
	if cfg.DB.Port != "5432" {
		t.Errorf("DB.Port = %q, want %q", cfg.DB.Port, "5432")
	}
	if cfg.DB.SSLMode != "require" {
		t.Errorf("DB.SSLMode = %q, want %q", cfg.DB.SSLMode, "require")
	}
}

func TestLoad_OverridesDefaults(t *testing.T) {
	setRequiredEnv(t)
	t.Setenv("HTTP_ADDR", ":9090")
	t.Setenv("LOG_LEVEL", "debug")
	t.Setenv("DB_PORT", "5433")

	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("Load() error = %v, want nil", err)
	}
	if cfg.HTTPAddr != ":9090" {
		t.Errorf("HTTPAddr = %q, want %q", cfg.HTTPAddr, ":9090")
	}
	if cfg.LogLevel != slog.LevelDebug {
		t.Errorf("LogLevel = %v, want %v", cfg.LogLevel, slog.LevelDebug)
	}
	if cfg.DB.Port != "5433" {
		t.Errorf("DB.Port = %q, want %q", cfg.DB.Port, "5433")
	}
}

func TestLoad_AggregatesMissingRequired(t *testing.T) {
	// Deliberately leave every required var unset.
	_, err := config.Load()
	if err == nil {
		t.Fatal("Load() error = nil, want aggregated missing-var error")
	}

	for _, want := range []string{"SERVICE_NAME", "OIDC_ISSUER_URL", "OIDC_AUDIENCE", "DB_HOST", "DB_USER", "DB_NAME"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not mention missing var %q", err.Error(), want)
		}
	}
}

func TestLoad_InvalidLogLevel(t *testing.T) {
	setRequiredEnv(t)
	t.Setenv("LOG_LEVEL", "verbose")

	_, err := config.Load()
	if err == nil {
		t.Fatal("Load() error = nil, want error for invalid LOG_LEVEL")
	}
	if !strings.Contains(err.Error(), "LOG_LEVEL") {
		t.Errorf("error %q does not mention LOG_LEVEL", err.Error())
	}
}
