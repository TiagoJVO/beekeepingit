// Package dbaccess is the Postgres data-access layer abstraction (NFR-ARC-2):
// a typed query layer (pgx + sqlc) and versioned migrations (goose) behind a
// small Config, instead of raw provider-specific calls scattered across
// services. See ../README.md for a worked example of switching endpoints,
// and ./sqlc for the sample migration + typed queries this package ships as
// a reference for future services to pattern-match.
package dbaccess

import (
	"fmt"
	"net"
	"net/url"
)

// Config holds the connection details for a Postgres database. Populate it
// from environment/config/secrets — never hardcode credentials.
type Config struct {
	Host     string
	Port     string // defaults to "5432" if empty
	User     string
	Password string
	Database string
	SSLMode  string // e.g. "require", "disable"; defaults to "require"
}

// DSN renders cfg as a connection string consumable by both pgxpool
// (Connect) and goose's database/sql driver (Migrate).
func (c Config) DSN() string {
	port := c.Port
	if port == "" {
		port = "5432"
	}
	sslMode := c.SSLMode
	if sslMode == "" {
		sslMode = "require"
	}

	u := url.URL{
		Scheme: "postgres",
		User:   url.UserPassword(c.User, c.Password),
		Host:   net.JoinHostPort(c.Host, port),
		Path:   "/" + c.Database,
	}
	q := url.Values{}
	q.Set("sslmode", sslMode)
	u.RawQuery = q.Encode()

	return u.String()
}

func (c Config) validate() error {
	if c.Host == "" || c.User == "" || c.Database == "" {
		return fmt.Errorf("dbaccess: host, user and database are required")
	}
	return nil
}
