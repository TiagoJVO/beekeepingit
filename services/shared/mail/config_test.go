package mail

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestLoadConfig_Defaults(t *testing.T) {
	t.Setenv("SMTP_HOST", "mailpit.beekeepingit.svc")
	t.Setenv("SMTP_FROM", "no-reply@example.org")
	t.Setenv("SMTP_PORT", "")
	t.Setenv("SMTP_USERNAME", "")
	t.Setenv("SMTP_PASSWORD", "")
	t.Setenv("SMTP_FROM_NAME", "")
	t.Setenv("SMTP_TLS", "")
	t.Setenv("SMTP_TIMEOUT", "")

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig() error = %v, want nil", err)
	}
	if cfg.Host != "mailpit.beekeepingit.svc" {
		t.Errorf("Host = %q, want mailpit.beekeepingit.svc", cfg.Host)
	}
	if cfg.Port != 587 {
		t.Errorf("Port = %d, want 587 (default)", cfg.Port)
	}
	if cfg.TLS != TLSStartTLS {
		t.Errorf("TLS = %q, want %q (default)", cfg.TLS, TLSStartTLS)
	}
	if cfg.Timeout != 10*time.Second {
		t.Errorf("Timeout = %v, want 10s (default)", cfg.Timeout)
	}
	if cfg.From != "no-reply@example.org" {
		t.Errorf("From = %q, want no-reply@example.org", cfg.From)
	}
}

func TestLoadConfig_NotConfigured(t *testing.T) {
	tests := []struct {
		name string
		host string
		from string
	}{
		{"missing host", "", "no-reply@example.org"},
		{"missing from", "mailpit.beekeepingit.svc", ""},
		{"missing both", "", ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("SMTP_HOST", tt.host)
			t.Setenv("SMTP_FROM", tt.from)

			_, err := LoadConfig()
			if !errors.Is(err, ErrNotConfigured) {
				t.Fatalf("LoadConfig() error = %v, want ErrNotConfigured", err)
			}
		})
	}
}

func TestLoadConfig_ParseErrors(t *testing.T) {
	tests := []struct {
		name string
		env  map[string]string
	}{
		{"bad port", map[string]string{"SMTP_PORT": "not-a-port"}},
		{"bad duration", map[string]string{"SMTP_TIMEOUT": "not-a-duration"}},
		{"unknown tls mode", map[string]string{"SMTP_TLS": "ssl3"}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("SMTP_HOST", "mailpit.beekeepingit.svc")
			t.Setenv("SMTP_FROM", "no-reply@example.org")
			for k, v := range tt.env {
				t.Setenv(k, v)
			}

			_, err := LoadConfig()
			if err == nil {
				t.Fatal("LoadConfig() error = nil, want a parse error")
			}
			if errors.Is(err, ErrNotConfigured) {
				t.Fatalf("LoadConfig() error = %v, want a parse error, not ErrNotConfigured", err)
			}
		})
	}
}

func TestNew_ValidatesConfig(t *testing.T) {
	base := Config{
		Host: "smtp.example.org",
		Port: 587,
		From: "no-reply@example.org",
		TLS:  TLSStartTLS,
	}

	tests := []struct {
		name    string
		mutate  func(c Config) Config
		wantErr bool
	}{
		{"valid", func(c Config) Config { return c }, false},
		{"missing host", func(c Config) Config { c.Host = ""; return c }, true},
		{"missing from", func(c Config) Config { c.From = ""; return c }, true},
		{"port zero", func(c Config) Config { c.Port = 0; return c }, true},
		{"port too large", func(c Config) Config { c.Port = 70000; return c }, true},
		{"unknown tls mode", func(c Config) Config { c.TLS = TLSMode("ssl3"); return c }, true},
		{"tls none is valid", func(c Config) Config { c.TLS = TLSNone; return c }, false},
		{"tls implicit is valid", func(c Config) Config { c.TLS = TLSImplicit; return c }, false},
		{"from with display name is rejected", func(c Config) Config {
			c.From = "Org <no-reply@example.org>"
			return c
		}, true},
		{"from with header break is rejected", func(c Config) Config {
			c.From = "no-reply@example.org\r\nBcc: attacker@evil.test"
			return c
		}, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := tt.mutate(base)
			_, err := New(cfg)
			if tt.wantErr && err == nil {
				t.Fatal("New() error = nil, want an error")
			}
			if !tt.wantErr && err != nil {
				t.Fatalf("New() error = %v, want nil", err)
			}
		})
	}
}

func TestUnconfigured_NeverDials(t *testing.T) {
	// A closed listener's address: any attempt to actually dial it fails
	// with a connection error, not ErrNotConfigured. Asserting
	// ErrNotConfigured here proves Send never tried to reach the network.
	ln, err := newTestListener(t)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close() // now guaranteed nothing is listening on addr

	sender := Unconfigured()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	err = sender.Send(ctx, Message{To: "someone@example.test", Subject: "hi", TextBody: "hi"})
	if !errors.Is(err, ErrNotConfigured) {
		t.Fatalf("Send() error = %v, want ErrNotConfigured (addr %s was never dialed)", err, addr)
	}
}
