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
	"regexp"
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
	// SearchPath, when set, is applied as the connection's schema search path.
	// A least-privilege per-service role (schema-per-service, D-6) has no rights
	// on `public`, so this points it at its own schema — where its tables live
	// and where goose creates its version table.
	SearchPath string
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
	if c.SearchPath != "" {
		// libpq/pgx honor `options=-c search_path=<schema>` on every connection.
		q.Set("options", "-c search_path="+c.SearchPath)
	}
	u.RawQuery = q.Encode()

	return u.String()
}

// validSchemaName matches a plain Postgres identifier: this is deliberately
// stricter than what Postgres itself allows (e.g. it rejects quoted
// identifiers/mixed case-preserving forms) because SearchPath's only
// legitimate values here are the schema-per-service names this repo itself
// assigns (D-6), never arbitrary user input.
var validSchemaName = regexp.MustCompile(`^[a-zA-Z_][a-zA-Z0-9_]*$`)

func (c Config) validate() error {
	if c.Host == "" || c.User == "" || c.Database == "" {
		return fmt.Errorf("dbaccess: host, user and database are required")
	}
	// SearchPath is concatenated into DSN's `options=-c search_path=<value>`
	// query parameter, which libpq/pgx pass straight through as extra
	// connection-time options. An unvalidated value (e.g. containing a
	// space) lets a caller inject additional `-c ...` flags into the
	// connection string (HIGH #3) — reject anything that isn't a plain
	// schema identifier before it ever reaches DSN().
	if c.SearchPath != "" && !validSchemaName.MatchString(c.SearchPath) {
		return fmt.Errorf("dbaccess: search path %q is not a valid schema identifier", c.SearchPath)
	}
	return nil
}
