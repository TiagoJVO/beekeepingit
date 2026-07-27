package dbaccess

import (
	"context"
	"strings"
	"testing"
)

func TestConfig_DSN(t *testing.T) {
	tests := []struct {
		name string
		cfg  Config
		want string
	}{
		{
			name: "defaults port and sslmode when empty",
			cfg: Config{
				Host:     "postgres",
				User:     "apiaries_svc",
				Password: "secret",
				Database: "beekeepingit",
			},
			want: "postgres://apiaries_svc:secret@postgres:5432/beekeepingit?sslmode=require",
		},
		{
			name: "honors explicit port and sslmode",
			cfg: Config{
				Host:     "127.0.0.1",
				Port:     "55432",
				User:     "u",
				Password: "p",
				Database: "d",
				SSLMode:  "disable",
			},
			want: "postgres://u:p@127.0.0.1:55432/d?sslmode=disable",
		},
		{
			name: "escapes special characters in credentials",
			cfg: Config{
				Host:     "postgres",
				User:     "user@org",
				Password: "p@ss/word #1",
				Database: "beekeepingit",
			},
			want: "postgres://user%40org:p%40ss%2Fword%20%231@postgres:5432/beekeepingit?sslmode=require",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.cfg.DSN(); got != tt.want {
				t.Errorf("DSN() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestConfig_validate(t *testing.T) {
	tests := []struct {
		name    string
		cfg     Config
		wantErr bool
	}{
		{name: "fully populated", cfg: Config{Host: "h", User: "u", Database: "d"}, wantErr: false},
		{name: "missing host", cfg: Config{User: "u", Database: "d"}, wantErr: true},
		{name: "missing user", cfg: Config{Host: "h", Database: "d"}, wantErr: true},
		{name: "missing database", cfg: Config{Host: "h", User: "u"}, wantErr: true},
		{name: "zero value", cfg: Config{}, wantErr: true},
		{name: "valid search path", cfg: Config{Host: "h", User: "u", Database: "d", SearchPath: "apiaries"}, wantErr: false},
		{name: "valid search path with underscore", cfg: Config{Host: "h", User: "u", Database: "d", SearchPath: "apiaries_svc"}, wantErr: false},
		// HIGH #3 regression: SearchPath is concatenated unvalidated into
		// libpq's `options=-c search_path=<value>` connection parameter
		// (DSN). A value containing a space lets a caller (or config typo)
		// inject additional `-c` options into the connection string.
		{name: "search path with space injects extra options", cfg: Config{Host: "h", User: "u", Database: "d", SearchPath: "public -c statement_timeout=1"}, wantErr: true},
		{name: "search path with -c flag", cfg: Config{Host: "h", User: "u", Database: "d", SearchPath: "-c"}, wantErr: true},
		{name: "search path starting with digit", cfg: Config{Host: "h", User: "u", Database: "d", SearchPath: "1invalid"}, wantErr: true},
		{name: "search path with special characters", cfg: Config{Host: "h", User: "u", Database: "d", SearchPath: "schema;drop table x"}, wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.cfg.validate()
			if (err != nil) != tt.wantErr {
				t.Errorf("validate() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

// TestConnect_InvalidConfig proves Connect fails fast on an invalid Config —
// before ever attempting a network call — so it needs no Postgres instance.
func TestConnect_InvalidConfig(t *testing.T) {
	_, err := Connect(context.Background(), Config{})
	if err == nil {
		t.Fatal("expected error for empty Config, got nil")
	}
	if !strings.Contains(err.Error(), "required") {
		t.Errorf("error = %q, want it to mention required fields", err.Error())
	}
}
