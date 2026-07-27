package store

import (
	"embed"
	"io/fs"
)

//go:embed migrations/*.sql
var embeddedMigrations embed.FS

// MigrationsFS returns this service's goose migrations, rooted at the
// migrations directory as goose.NewProvider (via dbaccess.Migrate) expects.
func MigrationsFS() fs.FS {
	sub, err := fs.Sub(embeddedMigrations, "migrations")
	if err != nil {
		panic(err) // unreachable: "migrations" is embedded at build time above.
	}
	return sub
}
