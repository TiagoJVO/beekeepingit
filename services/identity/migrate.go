package main

import (
	"context"
	"fmt"

	"github.com/TiagoJVO/beekeepingit/services/identity/store"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/config"
	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
)

// runMigrate applies this service's pending goose migrations, then returns —
// the "$s migrate" admin process (12-factor XII), run once per deploy by the
// migrate Job in charts/services, NEVER by the serving process.
//
// Why this is not done at startup any more (#541): the runtime role
// `identity_svc` deliberately does not own its tables, so it cannot run DDL at
// all. #62 moved history-table ownership to `beekeepingit` to make the audit
// log tamper-proof, which also — correctly — took ALTER away from the service.
// Migrating at startup meant the serving credential needed DDL rights, which
// is both the bug (a locked history table could never be migrated again) and a
// standing privilege the service should never hold: a role that can migrate
// can also DROP.
//
// Config comes from config.LoadDB, not config.Load: this process serves no
// HTTP, so it needs none of the OIDC settings and should not be given them.
func runMigrate(ctx context.Context) error {
	dbCfg, err := config.LoadDB()
	if err != nil {
		return fmt.Errorf("load db config: %w", err)
	}
	if err := dbaccess.Migrate(ctx, dbCfg.DSN(), store.MigrationsFS()); err != nil {
		return fmt.Errorf("migrate db: %w", err)
	}
	return nil
}
