package mail

import (
	"context"
	"errors"
	"fmt"
	"net/mail"
	"os"
	"strconv"
	"strings"
	"time"
)

// Config holds the connection details for an SMTP relay. Populate it from
// environment/config/secrets — never hardcode credentials. See LoadConfig
// for the environment-variable mapping.
type Config struct {
	Host     string
	Port     int
	Username string
	Password string
	// From is the envelope + header From address, e.g.
	// "no-reply@example.org". Must be a single bare address (no display
	// name) — use FromName for the display name.
	From     string
	FromName string // optional display name for the From header
	TLS      TLSMode
	Timeout  time.Duration
}

// LoadConfig reads Config from the environment: SMTP_HOST, SMTP_PORT
// (default 587), SMTP_USERNAME, SMTP_PASSWORD, SMTP_FROM, SMTP_FROM_NAME,
// SMTP_TLS (none|starttls|tls, default starttls), SMTP_TIMEOUT (Go
// duration, default 10s).
//
// Returns ErrNotConfigured when SMTP_HOST or SMTP_FROM is empty — that is a
// normal, non-fatal state (an environment with no relay provisioned yet),
// checked before any other parsing so a genuinely unconfigured environment
// never surfaces as a parse-error crash.
func LoadConfig() (Config, error) {
	host := os.Getenv("SMTP_HOST")
	from := os.Getenv("SMTP_FROM")
	if host == "" || from == "" {
		return Config{}, ErrNotConfigured
	}

	var errs []error

	portStr := envDefault("SMTP_PORT", "587")
	port, err := strconv.Atoi(portStr)
	if err != nil {
		errs = append(errs, fmt.Errorf("mail: SMTP_PORT %q is not a valid integer: %w", portStr, err))
	}

	tlsStr := envDefault("SMTP_TLS", string(TLSStartTLS))
	tlsMode := TLSMode(tlsStr)
	switch tlsMode {
	case TLSNone, TLSStartTLS, TLSImplicit:
	default:
		errs = append(errs, fmt.Errorf("mail: SMTP_TLS %q is not one of none/starttls/tls", tlsStr))
	}

	timeoutStr := envDefault("SMTP_TIMEOUT", "10s")
	timeout, err := time.ParseDuration(timeoutStr)
	if err != nil {
		errs = append(errs, fmt.Errorf("mail: SMTP_TIMEOUT %q is not a valid duration: %w", timeoutStr, err))
	}

	if len(errs) > 0 {
		return Config{}, errors.Join(errs...)
	}

	return Config{
		Host:     host,
		Port:     port,
		Username: os.Getenv("SMTP_USERNAME"),
		Password: os.Getenv("SMTP_PASSWORD"),
		From:     from,
		FromName: os.Getenv("SMTP_FROM_NAME"),
		TLS:      tlsMode,
		Timeout:  timeout,
	}, nil
}

func envDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// validate rejects a Config that must never reach New's caller — host,
// from, port range and TLS mode, per New's fail-fast contract (a bad config
// is rejected at construction, not deferred to the first Send). From is
// also checked here for header-injection safety and address shape, since
// (unlike To) it is fixed for the sender's whole lifetime rather than
// re-validated per message.
func (c Config) validate() error {
	if c.Host == "" {
		return fmt.Errorf("mail: host is required")
	}
	if c.From == "" {
		return fmt.Errorf("mail: from is required")
	}
	if c.Port < 1 || c.Port > 65535 {
		return fmt.Errorf("mail: port %d is out of range 1-65535", c.Port)
	}
	switch c.TLS {
	case TLSNone, TLSStartTLS, TLSImplicit:
	default:
		return fmt.Errorf("mail: tls mode %q is not one of none/starttls/tls", c.TLS)
	}
	if strings.ContainsAny(c.From, "\r\n") {
		return fmt.Errorf("mail: from: %w", ErrInvalidHeader)
	}
	if strings.ContainsAny(c.FromName, "\r\n") {
		return fmt.Errorf("mail: from name: %w", ErrInvalidHeader)
	}
	addr, err := mail.ParseAddress(c.From)
	if err != nil {
		return fmt.Errorf("mail: from: %w", err)
	}
	if addr.Name != "" {
		return fmt.Errorf("mail: from must be a bare address (no display name); use FromName")
	}
	return nil
}

// New builds an SMTP Sender from cfg, validating it up front (host, from,
// port range, TLS mode) so a bad config is an error here rather than a
// mystery at first Send.
func New(cfg Config) (Sender, error) {
	if err := cfg.validate(); err != nil {
		return nil, err
	}
	return &smtpSender{cfg: cfg}, nil
}

// unconfiguredSender is what a service with no SMTP relay provisioned
// (LoadConfig returned ErrNotConfigured) runs with: the service still
// starts and serves traffic, and each attempted send fails honestly and
// individually instead of the whole service refusing to start.
type unconfiguredSender struct{}

func (unconfiguredSender) Send(context.Context, Message) error {
	return ErrNotConfigured
}

// Unconfigured returns a Sender whose Send always fails with
// ErrNotConfigured. It never dials the network.
func Unconfigured() Sender {
	return unconfiguredSender{}
}
