package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	jose "github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	tcpostgres "github.com/testcontainers/testcontainers-go/modules/postgres"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/config"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/health"
	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
	sqlcgen "github.com/TiagoJVO/beekeepingit/services/shared/dbaccess/sqlc/gen"
)

const testAudience = "beekeepingit-example"

// testIDP is a minimal stand-in for an OIDC provider's discovery + JWKS
// endpoints — see services/servicetemplate/authn's own tests for the
// key-rotation scenario; this one just needs to mint one valid token.
type testIDP struct {
	mu   sync.Mutex
	keys []jose.JSONWebKey
	srv  *httptest.Server
}

func newTestIDP(t *testing.T) *testIDP {
	idp := &testIDP{}
	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/openid-configuration", func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]string{
			"issuer":   idp.srv.URL,
			"jwks_uri": idp.srv.URL + "/jwks",
		})
	})
	mux.HandleFunc("/jwks", func(w http.ResponseWriter, _ *http.Request) {
		idp.mu.Lock()
		defer idp.mu.Unlock()
		_ = json.NewEncoder(w).Encode(jose.JSONWebKeySet{Keys: append([]jose.JSONWebKey{}, idp.keys...)})
	})
	idp.srv = httptest.NewServer(mux)
	t.Cleanup(idp.srv.Close)
	return idp
}

func mintToken(t *testing.T, priv *rsa.PrivateKey, kid, issuer string) string {
	t.Helper()
	signer, err := jose.NewSigner(
		jose.SigningKey{Algorithm: jose.RS256, Key: priv},
		(&jose.SignerOptions{}).WithType("JWT").WithHeader("kid", kid),
	)
	if err != nil {
		t.Fatalf("new signer: %v", err)
	}
	claims := jwt.Claims{
		Issuer:   issuer,
		Subject:  "beekeeper-1",
		Audience: jwt.Audience{testAudience},
		Expiry:   jwt.NewNumericDate(time.Now().Add(time.Hour)),
		IssuedAt: jwt.NewNumericDate(time.Now()),
	}
	raw, err := jwt.Signed(signer).Claims(claims).Serialize()
	if err != nil {
		t.Fatalf("serialize token: %v", err)
	}
	return raw
}

// TestExampleService_EndToEnd wires config, DB access, JWT auth and health
// checks exactly as example/main.go's run() does, then exercises the whole
// chain over real HTTP: health probes, a rejected unauthenticated request,
// and an authenticated GET /v1/example-items round-trip against data
// written through services/shared/dbaccess.
func TestExampleService_EndToEnd(t *testing.T) {
	ctx := context.Background()

	const (
		dbUser = "beekeepingit_test"
		dbPass = "beekeepingit_test"
		dbName = "beekeepingit_test"
	)
	pgContainer, err := tcpostgres.Run(ctx, "postgres:16-alpine",
		tcpostgres.WithUsername(dbUser),
		tcpostgres.WithPassword(dbPass),
		tcpostgres.WithDatabase(dbName),
		tcpostgres.BasicWaitStrategies(),
	)
	if err != nil {
		t.Fatalf("start postgres container: %v", err)
	}
	t.Cleanup(func() {
		if err := pgContainer.Terminate(ctx); err != nil {
			t.Logf("terminate postgres container: %v", err)
		}
	})
	host, err := pgContainer.Host(ctx)
	if err != nil {
		t.Fatalf("container host: %v", err)
	}
	port, err := pgContainer.MappedPort(ctx, "5432/tcp")
	if err != nil {
		t.Fatalf("container mapped port: %v", err)
	}

	dbCfg := dbaccess.Config{
		Host: host, Port: port.Port(), User: dbUser, Password: dbPass, Database: dbName, SSLMode: "disable",
	}
	if err := dbaccess.Migrate(ctx, dbCfg.DSN(), dbaccess.MigrationsFS()); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	pool, err := dbaccess.Connect(ctx, dbCfg)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)

	seedID := pgtype.UUID{Bytes: [16]byte(uuid.New()), Valid: true}
	if _, err := sqlcgen.New(pool).CreateItem(ctx, sqlcgen.CreateItemParams{ID: seedID, Name: "first hive check"}); err != nil {
		t.Fatalf("seed item: %v", err)
	}

	idp := newTestIDP(t)
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate RSA key: %v", err)
	}
	idp.keys = append(idp.keys, jose.JSONWebKey{Key: &priv.PublicKey, KeyID: "key-1", Algorithm: "RS256", Use: "sig"})

	authnMW, err := authn.NewMiddleware(ctx, authn.Config{IssuerURL: idp.srv.URL, Audience: testAudience})
	if err != nil {
		t.Fatalf("build authn middleware: %v", err)
	}

	cfg := config.Config{ServiceName: "example-test", HTTPAddr: ":0", LogLevel: slog.LevelInfo, DB: dbCfg}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	checks := health.NewRegistry()
	checks.Register("db", func(ctx context.Context) error { return pool.Ping(ctx) })

	srv, err := servicetemplate.New(cfg, nil, logger, checks)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	srv.Mount("/v1/example-items", authnMW(itemsHandler(pool)))

	get := func(path, authHeader string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, path, nil)
		if authHeader != "" {
			req.Header.Set("Authorization", authHeader)
		}
		srv.Router().ServeHTTP(rec, req)
		return rec
	}

	if rec := get("/healthz", ""); rec.Code != http.StatusOK {
		t.Errorf("/healthz status = %d, want %d", rec.Code, http.StatusOK)
	}
	if rec := get("/readyz", ""); rec.Code != http.StatusOK {
		t.Errorf("/readyz status = %d, want %d, body = %s", rec.Code, http.StatusOK, rec.Body.String())
	}

	if rec := get("/v1/example-items", ""); rec.Code != http.StatusUnauthorized {
		t.Errorf("unauthenticated status = %d, want %d", rec.Code, http.StatusUnauthorized)
	} else if ct := rec.Header().Get("Content-Type"); ct != "application/problem+json" {
		t.Errorf("unauthenticated Content-Type = %q, want application/problem+json", ct)
	}

	token := mintToken(t, priv, "key-1", idp.srv.URL)
	rec := get("/v1/example-items", "Bearer "+token)
	if rec.Code != http.StatusOK {
		t.Fatalf("authenticated status = %d, want %d, body = %s", rec.Code, http.StatusOK, rec.Body.String())
	}
	var items []sqlcgen.PlatformExampleItem
	if err := json.Unmarshal(rec.Body.Bytes(), &items); err != nil {
		t.Fatalf("decode items: %v", err)
	}
	if len(items) != 1 || items[0].Name != "first hive check" {
		t.Errorf("items = %+v, want one item named %q", items, "first hive check")
	}
}
