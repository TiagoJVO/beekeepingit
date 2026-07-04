package dbaccess

import (
	"embed"
	"io/fs"
)

//go:embed migrations/*.sql
var embeddedMigrations embed.FS

// MigrationsFS returns this package's own demo migrations (see ./sqlc),
// rooted at the migrations directory as goose.NewProvider expects. It
// exists so the integration test — and any caller wanting to see the
// pattern in action — doesn't need to know this package's internal layout.
func MigrationsFS() fs.FS {
	sub, err := fs.Sub(embeddedMigrations, "migrations")
	if err != nil {
		panic(err) // unreachable: "migrations" is embedded at build time above.
	}
	return sub
}
