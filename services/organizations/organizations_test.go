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

	"github.com/TiagoJVO/beekeepingit/services/organizations/api"
	"github.com/TiagoJVO/beekeepingit/services/organizations/store"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn/authtest"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/config"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/contracttest"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/health"
	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
)

const organizationsTestAudience = "beekeepingit-organizations"

// stubIdentity stands in for the identity service's internal resolve
// endpoint (GET /internal/users/by-sub/{sub}) — mirrors
// servicetemplate/authn's own stubResolveServers pattern. Every sub not in
// users gets a 404, matching identity's real "unknown subject" response.
type stubIdentity struct {
	srv   *httptest.Server
	users map[string]string // sub -> user_id
}

func newStubIdentity(t *testing.T, users map[string]string) *stubIdentity {
	t.Helper()
	s := &stubIdentity{users: users}
	s.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") == "" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		const prefix = "/internal/users/by-sub/"
		sub := r.URL.Path[len(prefix):]
		userID, ok := s.users[sub]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"user_id": userID})
	}))
	t.Cleanup(s.srv.Close)
	return s
}

type orgFixture struct {
	srv      *servicetemplate.Server
	idp      *authtest.IDP
	identity *stubIdentity
}

// newOrgFixture wires the service as run() does (minus the internal
// membership-resolve router, irrelevant to these client-facing tests),
// mounting /v1 behind a real authn.NewMiddleware chain against a fake IDP,
// with a stub identity service backing the user-id resolve step. Mirrors
// identity/profile_test.go's newProfileFixture and this package's own
// main_test.go Postgres/createSchema setup.
func newOrgFixture(t *testing.T, users map[string]string) *orgFixture {
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
	createSchema(ctx, t, dbCfg, "organizations")
	if err := dbaccess.Migrate(ctx, dbCfg.DSN(), store.MigrationsFS()); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	pool, err := dbaccess.Connect(ctx, dbCfg)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)

	idp := authtest.NewIDP(t)
	authnMW, err := authn.NewMiddleware(ctx, authn.Config{IssuerURL: idp.Issuer(), Audience: organizationsTestAudience})
	if err != nil {
		t.Fatalf("build authn middleware: %v", err)
	}
	identity := newStubIdentity(t, users)

	cfg := config.Config{ServiceName: "organizations-test", HTTPAddr: ":0", LogLevel: slog.LevelInfo, DB: dbCfg}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	checks := health.NewRegistry()
	checks.Register("db", func(ctx context.Context) error { return pool.Ping(ctx) })

	srv, err := servicetemplate.New(cfg, nil, logger, checks)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	userResolver := api.NewHTTPUserResolver(identity.srv.URL, nil)
	srv.Mount("/v1", authnMW(api.PublicRouter(pool, userResolver)))

	return &orgFixture{srv: srv, idp: idp, identity: identity}
}

func (f *orgFixture) do(t *testing.T, method, path, bearer string, body any) *httptest.ResponseRecorder {
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

func (f *orgFixture) token(t *testing.T, sub string) string {
	t.Helper()
	return "Bearer " + f.idp.Mint(t, sub, organizationsTestAudience)
}

// TestCreateOrganization_Unauthenticated asserts POST requires a bearer token.
func TestCreateOrganization_Unauthenticated(t *testing.T) {
	f := newOrgFixture(t, nil)
	rec := f.do(t, http.MethodPost, "/v1/organizations", "", map[string]string{
		"id": "d0000000-0000-7000-8000-000000000001", "name": "Dev Apiary Co.",
	})
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusUnauthorized)
	}
}

// TestCreateOrganization_MakesCreatorAdmin covers the core AC (D-3): creating
// an org auto-assigns the caller as its active admin member, and that
// membership is immediately visible to GET /organizations/me and the
// internal active-membership resolve endpoint other services depend on.
func TestCreateOrganization_MakesCreatorAdmin(t *testing.T) {
	sub := "11111111-1111-4111-8111-111111111111"
	userID := "a0000000-0000-7000-8000-000000000001"
	f := newOrgFixture(t, map[string]string{sub: userID})
	bearer := f.token(t, sub)

	orgID := "b0000000-0000-7000-8000-000000000001"
	rec := f.do(t, http.MethodPost, "/v1/organizations", bearer, map[string]string{
		"id": orgID, "name": "Dev Apiary Co.", "address": "Serra Norte",
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("POST status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	if loc := rec.Header().Get("Location"); loc != "/v1/organizations/"+orgID {
		t.Errorf("Location = %q, want /v1/organizations/%s", loc, orgID)
	}
	var org api.OrganizationResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &org); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if org.ID != orgID || org.Name != "Dev Apiary Co." || org.Address != "Serra Norte" {
		t.Errorf("created org = %+v, want id/name/address to match the request", org)
	}
	if org.CreatedBy != userID {
		t.Errorf("created_by = %q, want %q", org.CreatedBy, userID)
	}

	// The creator can immediately fetch their own org (D-3 admin membership
	// is visible in the very same request cycle, per the AC).
	recMe := f.do(t, http.MethodGet, "/v1/organizations/me", bearer, nil)
	if recMe.Code != http.StatusOK {
		t.Fatalf("GET /organizations/me status = %d, want 200, body = %s", recMe.Code, recMe.Body.String())
	}
	var me api.OrganizationResponse
	if err := json.Unmarshal(recMe.Body.Bytes(), &me); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if me.ID != orgID {
		t.Errorf("GET /organizations/me id = %q, want %q", me.ID, orgID)
	}

	// GET /organizations/{orgId} for the caller's own org succeeds too.
	recByID := f.do(t, http.MethodGet, "/v1/organizations/"+orgID, bearer, nil)
	if recByID.Code != http.StatusOK {
		t.Fatalf("GET /organizations/%s status = %d, want 200, body = %s", orgID, recByID.Code, recByID.Body.String())
	}

	// That the internal /internal/memberships/active resolve endpoint (which
	// other services' org-resolver middleware calls) sees this same active
	// admin membership is covered by main_test.go's
	// TestOrganizationsService_ResolveActiveMembership — this fixture only
	// mounts the client-facing /v1 routes.
}

// TestCreateOrganization_MissingRequiredFields_Returns422 covers required
// field validation (name; id must be a UUID).
func TestCreateOrganization_MissingRequiredFields_Returns422(t *testing.T) {
	sub := "22222222-2222-4222-8222-222222222222"
	f := newOrgFixture(t, map[string]string{sub: "a0000000-0000-7000-8000-000000000002"})
	bearer := f.token(t, sub)

	rec := f.do(t, http.MethodPost, "/v1/organizations", bearer, map[string]string{
		"id": "not-a-uuid", "name": "  ",
	})
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
	fields := map[string]bool{}
	for _, e := range p.Errors {
		fields[e.Field] = true
	}
	if !fields["id"] || !fields["name"] {
		t.Errorf("errors = %+v, want fields id and name", p.Errors)
	}
}

// TestCreateOrganization_DuplicateID_Returns409 covers the client-generated
// id collision path (a retried create with a new body but the same id).
func TestCreateOrganization_DuplicateID_Returns409(t *testing.T) {
	sub := "33333333-3333-4333-8333-333333333333"
	f := newOrgFixture(t, map[string]string{sub: "a0000000-0000-7000-8000-000000000003"})
	bearer := f.token(t, sub)
	orgID := "b0000000-0000-7000-8000-000000000003"

	first := f.do(t, http.MethodPost, "/v1/organizations", bearer, map[string]string{"id": orgID, "name": "First"})
	if first.Code != http.StatusCreated {
		t.Fatalf("first POST status = %d, want 201, body = %s", first.Code, first.Body.String())
	}

	second := f.do(t, http.MethodPost, "/v1/organizations", bearer, map[string]string{"id": orgID, "name": "Second"})
	if second.Code != http.StatusConflict {
		t.Fatalf("second POST status = %d, want 409, body = %s", second.Code, second.Body.String())
	}
}

// TestCreateOrganization_UnknownUser_Returns403 covers a verified token whose
// subject has no identity.users row yet.
func TestCreateOrganization_UnknownUser_Returns403(t *testing.T) {
	f := newOrgFixture(t, nil) // no known subs
	sub := "44444444-4444-4444-8444-444444444444"
	bearer := f.token(t, sub)

	rec := f.do(t, http.MethodPost, "/v1/organizations", bearer, map[string]string{
		"id": "b0000000-0000-7000-8000-000000000004", "name": "Ghost Org",
	})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403, body = %s", rec.Code, rec.Body.String())
	}
}

// TestGetMyOrganization_NoMembership_Returns404 is the exact signal the
// client's org-completion gate needs (AC bullet 3): a user who hasn't
// created or joined an org yet gets 404 from GET /organizations/me.
func TestGetMyOrganization_NoMembership_Returns404(t *testing.T) {
	sub := "55555555-5555-4555-8555-555555555555"
	userID := "a0000000-0000-7000-8000-000000000005"
	f := newOrgFixture(t, map[string]string{sub: userID})
	bearer := f.token(t, sub)

	rec := f.do(t, http.MethodGet, "/v1/organizations/me", bearer, nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}
}

// TestGetOrganization_OtherOrg_Returns404 asserts {orgId} scope enforcement:
// a caller cannot read an org that isn't their own, and gets 404 (not 403) so
// the API never confirms the other org's existence (ADR-0002).
func TestGetOrganization_OtherOrg_Returns404(t *testing.T) {
	subA := "66666666-6666-4666-8666-666666666666"
	userA := "a0000000-0000-7000-8000-000000000006"
	subB := "77777777-7777-4777-8777-777777777777"
	userB := "a0000000-0000-7000-8000-000000000007"
	f := newOrgFixture(t, map[string]string{subA: userA, subB: userB})

	bearerA := f.token(t, subA)
	orgA := "b0000000-0000-7000-8000-000000000006"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", bearerA, map[string]string{"id": orgA, "name": "Org A"}); rec.Code != http.StatusCreated {
		t.Fatalf("create org A status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	bearerB := f.token(t, subB)
	orgB := "b0000000-0000-7000-8000-000000000007"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", bearerB, map[string]string{"id": orgB, "name": "Org B"}); rec.Code != http.StatusCreated {
		t.Fatalf("create org B status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	// B tries to read A's org by id — 404, not 403.
	rec := f.do(t, http.MethodGet, "/v1/organizations/"+orgA, bearerB, nil)
	if rec.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}
}

// TestOrganizations_ResponsesConformToOpenAPIContract validates the real
// POST/GET response bodies against
// contracts/openapi/organizations.openapi.yaml (#153 "contract tests at
// boundaries" convention).
func TestOrganizations_ResponsesConformToOpenAPIContract(t *testing.T) {
	doc, err := contracttest.Load("../../contracts/openapi/organizations.openapi.yaml")
	if err != nil {
		t.Fatalf("load contract: %v", err)
	}

	sub := "88888888-8888-4888-8888-888888888888"
	userID := "a0000000-0000-7000-8000-000000000008"
	f := newOrgFixture(t, map[string]string{sub: userID})
	bearer := f.token(t, sub)
	orgID := "b0000000-0000-7000-8000-000000000008"

	recPost := f.do(t, http.MethodPost, "/v1/organizations", bearer, map[string]string{"id": orgID, "name": "Contract Co."})
	if recPost.Code != http.StatusCreated {
		t.Fatalf("POST status = %d, want 201, body = %s", recPost.Code, recPost.Body.String())
	}
	doc.ValidateResponseBody(t, http.MethodPost, "/v1/organizations", http.StatusCreated, recPost.Body.Bytes())

	recMe := f.do(t, http.MethodGet, "/v1/organizations/me", bearer, nil)
	if recMe.Code != http.StatusOK {
		t.Fatalf("GET /organizations/me status = %d, want 200, body = %s", recMe.Code, recMe.Body.String())
	}
	doc.ValidateResponseBody(t, http.MethodGet, "/v1/organizations/me", http.StatusOK, recMe.Body.Bytes())

	recByID := f.do(t, http.MethodGet, "/v1/organizations/"+orgID, bearer, nil)
	if recByID.Code != http.StatusOK {
		t.Fatalf("GET /organizations/%s status = %d, want 200, body = %s", orgID, recByID.Code, recByID.Body.String())
	}
	doc.ValidateResponseBody(t, http.MethodGet, "/v1/organizations/"+orgID, http.StatusOK, recByID.Body.Bytes())
}
