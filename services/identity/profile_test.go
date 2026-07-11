package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	tcpostgres "github.com/testcontainers/testcontainers-go/modules/postgres"

	"github.com/TiagoJVO/beekeepingit/services/identity/api"
	"github.com/TiagoJVO/beekeepingit/services/identity/store"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn/authtest"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/config"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/contracttest"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/health"
	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
)

const profileTestAudience = "beekeepingit-identity"

type profileFixture struct {
	srv *servicetemplate.Server
	idp *authtest.IDP
}

// newProfileFixture wires the service as run() does, mounting the /v1 profile
// routes behind a real authn.NewMiddleware chain against a fake IDP — mirrors
// TestIdentityService_ResolveBySub's setup in main_test.go (same
// testcontainers-go Postgres + createSchema pattern, reused from that file).
func newProfileFixture(t *testing.T) *profileFixture {
	t.Helper()
	ctx := context.Background()

	const (
		dbUser = "beekeepingit_test"
		dbPass = "beekeepingit_test"
		dbName = "beekeepingit_test"
	)
	pg, err := tcpostgres.Run(ctx, "postgres:16-alpine",
		tcpostgres.WithUsername(dbUser),
		tcpostgres.WithPassword(dbPass),
		tcpostgres.WithDatabase(dbName),
		tcpostgres.BasicWaitStrategies(),
	)
	if err != nil {
		t.Fatalf("start postgres container: %v", err)
	}
	t.Cleanup(func() {
		if err := pg.Terminate(ctx); err != nil {
			t.Logf("terminate postgres container: %v", err)
		}
	})
	host, err := pg.Host(ctx)
	if err != nil {
		t.Fatalf("container host: %v", err)
	}
	port, err := pg.MappedPort(ctx, "5432/tcp")
	if err != nil {
		t.Fatalf("container mapped port: %v", err)
	}

	dbCfg := dbaccess.Config{
		Host: host, Port: port.Port(), User: dbUser, Password: dbPass, Database: dbName, SSLMode: "disable",
	}
	createSchema(ctx, t, dbCfg, "identity")
	if err := dbaccess.Migrate(ctx, dbCfg.DSN(), store.MigrationsFS()); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	pool, err := dbaccess.Connect(ctx, dbCfg)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)

	idp := authtest.NewIDP(t)
	authnMW, err := authn.NewMiddleware(ctx, authn.Config{IssuerURL: idp.Issuer(), Audience: profileTestAudience})
	if err != nil {
		t.Fatalf("build authn middleware: %v", err)
	}

	cfg := config.Config{ServiceName: "identity-test", HTTPAddr: ":0", LogLevel: slog.LevelInfo, DB: dbCfg}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	checks := health.NewRegistry()
	checks.Register("db", func(ctx context.Context) error { return pool.Ping(ctx) })

	srv, err := servicetemplate.New(cfg, nil, logger, checks)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	srv.Mount("/v1", authnMW(api.PublicRouter(pool)))

	return &profileFixture{srv: srv, idp: idp}
}

func (f *profileFixture) do(t *testing.T, method, path, bearer string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var r io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("marshal body: %v", err)
		}
		r = bytes.NewReader(b)
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(method, path, r)
	if bearer != "" {
		req.Header.Set("Authorization", bearer)
	}
	f.srv.Router().ServeHTTP(rec, req)
	return rec
}

func (f *profileFixture) token(t *testing.T, sub string) string {
	t.Helper()
	return "Bearer " + f.idp.Mint(t, sub, profileTestAudience)
}

// TestProfile_Unauthenticated asserts GET/PATCH both require a bearer token.
func TestProfile_Unauthenticated(t *testing.T) {
	f := newProfileFixture(t)

	if rec := f.do(t, http.MethodGet, "/v1/profile", "", nil); rec.Code != http.StatusUnauthorized {
		t.Errorf("GET unauthenticated status = %d, want %d", rec.Code, http.StatusUnauthorized)
	}
	if rec := f.do(t, http.MethodPatch, "/v1/profile", "", map[string]string{"name": "x"}); rec.Code != http.StatusUnauthorized {
		t.Errorf("PATCH unauthenticated status = %d, want %d", rec.Code, http.StatusUnauthorized)
	}
}

// TestProfile_FirstGetCreatesRow asserts a brand-new sub's first GET
// lazily creates the identity.users row with an incomplete profile.
func TestProfile_FirstGetCreatesRow(t *testing.T) {
	f := newProfileFixture(t)
	sub := "22222222-2222-4222-8222-222222222222"

	rec := f.do(t, http.MethodGet, "/v1/profile", f.token(t, sub), nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var p api.ProfileResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &p); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if p.Name != "" || p.Email != "" {
		t.Errorf("new profile name/email = %q/%q, want both empty", p.Name, p.Email)
	}
	if p.ProfileComplete {
		t.Error("profile_complete = true for a brand-new profile, want false")
	}
	if p.ID == "" {
		t.Error("id is empty, want a generated UUID")
	}

	// A second GET for the same sub returns the same row (not a fresh one).
	rec2 := f.do(t, http.MethodGet, "/v1/profile", f.token(t, sub), nil)
	var p2 api.ProfileResponse
	if err := json.Unmarshal(rec2.Body.Bytes(), &p2); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if p2.ID != p.ID {
		t.Errorf("second GET id = %q, want %q (same row)", p2.ID, p.ID)
	}
}

// TestProfile_PatchNameAndEmail_CompletesProfile covers the onboarding path:
// submitting name+email together completes the profile and is reflected on
// a subsequent GET.
func TestProfile_PatchNameAndEmail_CompletesProfile(t *testing.T) {
	f := newProfileFixture(t)
	sub := "33333333-3333-4333-8333-333333333333"
	bearer := f.token(t, sub)

	// First-login GET establishes the row.
	f.do(t, http.MethodGet, "/v1/profile", bearer, nil)

	rec := f.do(t, http.MethodPatch, "/v1/profile", bearer, map[string]string{
		"name": "Ana Silva", "email": "ana@example.com",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("PATCH status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var p api.ProfileResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &p); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if p.Name != "Ana Silva" || p.Email != "ana@example.com" {
		t.Errorf("patched name/email = %q/%q, want Ana Silva/ana@example.com", p.Name, p.Email)
	}
	if !p.ProfileComplete {
		t.Error("profile_complete = false after name+email set, want true")
	}

	// Subsequent GET reflects the update.
	recGet := f.do(t, http.MethodGet, "/v1/profile", bearer, nil)
	var got api.ProfileResponse
	if err := json.Unmarshal(recGet.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.Name != "Ana Silva" || !got.ProfileComplete {
		t.Errorf("GET after PATCH = %+v, want name Ana Silva and complete", got)
	}
}

// TestProfile_PatchLocaleOnly_IsPartial asserts a locale-only PATCH doesn't
// disturb name/email (partial-update semantics, PATCH not PUT).
func TestProfile_PatchLocaleOnly_IsPartial(t *testing.T) {
	f := newProfileFixture(t)
	sub := "44444444-4444-4444-8444-444444444444"
	bearer := f.token(t, sub)
	f.do(t, http.MethodGet, "/v1/profile", bearer, nil)
	f.do(t, http.MethodPatch, "/v1/profile", bearer, map[string]string{
		"name": "Beatriz", "email": "bea@example.com",
	})

	rec := f.do(t, http.MethodPatch, "/v1/profile", bearer, map[string]string{"locale": "pt"})
	if rec.Code != http.StatusOK {
		t.Fatalf("locale-only PATCH status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var p api.ProfileResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &p); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if p.Locale != "pt" {
		t.Errorf("locale = %q, want pt", p.Locale)
	}
	if p.Name != "Beatriz" || p.Email != "bea@example.com" {
		t.Errorf("name/email changed by locale-only PATCH: %+v", p)
	}
}

// TestProfile_PatchEmptyName_Returns422 covers required-field validation.
func TestProfile_PatchEmptyName_Returns422(t *testing.T) {
	f := newProfileFixture(t)
	sub := "55555555-5555-4555-8555-555555555555"
	bearer := f.token(t, sub)
	f.do(t, http.MethodGet, "/v1/profile", bearer, nil)

	rec := f.do(t, http.MethodPatch, "/v1/profile", bearer, map[string]string{"name": ""})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422, body = %s", rec.Code, rec.Body.String())
	}
	var p struct {
		Errors []struct {
			Field string `json:"field"`
		} `json:"errors"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &p); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(p.Errors) != 1 || p.Errors[0].Field != "name" {
		t.Errorf("errors = %+v, want one error on field \"name\"", p.Errors)
	}
}

// TestProfile_PatchMalformedEmail_Returns422 covers email format validation.
func TestProfile_PatchMalformedEmail_Returns422(t *testing.T) {
	f := newProfileFixture(t)
	sub := "66666666-6666-4666-8666-666666666666"
	bearer := f.token(t, sub)
	f.do(t, http.MethodGet, "/v1/profile", bearer, nil)

	rec := f.do(t, http.MethodPatch, "/v1/profile", bearer, map[string]string{"email": "not-an-email"})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422, body = %s", rec.Code, rec.Body.String())
	}
	var p struct {
		Errors []struct {
			Field string `json:"field"`
		} `json:"errors"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &p); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(p.Errors) != 1 || p.Errors[0].Field != "email" {
		t.Errorf("errors = %+v, want one error on field \"email\"", p.Errors)
	}
}

// TestProfile_ResponsesConformToOpenAPIContract validates the real GET/PATCH
// response bodies against contracts/openapi/identity.openapi.yaml — the
// "contract tests at boundaries" convention (#153).
func TestProfile_ResponsesConformToOpenAPIContract(t *testing.T) {
	doc, err := contracttest.Load("../../contracts/openapi/identity.openapi.yaml")
	if err != nil {
		t.Fatalf("load contract: %v", err)
	}

	f := newProfileFixture(t)
	sub := "77777777-7777-4777-8777-777777777777"
	bearer := f.token(t, sub)

	recGet := f.do(t, http.MethodGet, "/v1/profile", bearer, nil)
	if recGet.Code != http.StatusOK {
		t.Fatalf("GET status = %d, want 200", recGet.Code)
	}
	doc.ValidateResponseBody(t, http.MethodGet, "/v1/profile", http.StatusOK, recGet.Body.Bytes())

	recPatch := f.do(t, http.MethodPatch, "/v1/profile", bearer, map[string]string{
		"name": "Carlos", "email": "carlos@example.com",
	})
	if recPatch.Code != http.StatusOK {
		t.Fatalf("PATCH status = %d, want 200", recPatch.Code)
	}
	doc.ValidateResponseBody(t, http.MethodPatch, "/v1/profile", http.StatusOK, recPatch.Body.Bytes())
}
