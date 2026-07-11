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
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
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

// stubUser is what the stub identity server knows about a subject —
// mirrors identity's real UserResponse (user_id + email; #27's
// accept-on-login path needs the email half too).
type stubUser struct {
	UserID string
	Email  string
}

// stubIdentity stands in for the identity service's internal resolve
// endpoint (GET /internal/users/by-sub/{sub}) — mirrors
// servicetemplate/authn's own stubResolveServers pattern. Every sub not in
// users gets a 404, matching identity's real "unknown subject" response.
type stubIdentity struct {
	srv   *httptest.Server
	users map[string]stubUser // sub -> user
}

// newStubIdentity starts the stub identity server backing users (sub ->
// user). Called from newOrgFixtureWithEmails; newOrgFixture (sub -> user_id
// only, most of this file's coverage predates #27's accept-on-login path)
// converts its simpler map and delegates to newOrgFixtureWithEmails.
func newStubIdentity(t *testing.T, users map[string]stubUser) *stubIdentity {
	t.Helper()
	s := &stubIdentity{users: users}
	s.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") == "" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		const prefix = "/internal/users/by-sub/"
		sub := r.URL.Path[len(prefix):]
		u, ok := s.users[sub]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"user_id": u.UserID, "email": u.Email})
	}))
	t.Cleanup(s.srv.Close)
	return s
}

type orgFixture struct {
	srv      *servicetemplate.Server
	idp      *authtest.IDP
	identity *stubIdentity
	pool     *pgxpool.Pool
}

// newOrgFixture wires the service as run() does (minus the internal
// membership-resolve router, irrelevant to these client-facing tests),
// mounting /v1 behind a real authn.NewMiddleware chain against a fake IDP,
// with a stub identity service backing the user-id resolve step. Mirrors
// identity/profile_test.go's newProfileFixture and this package's own
// main_test.go Postgres/createSchema setup.
func newOrgFixture(t *testing.T, users map[string]string) *orgFixture {
	t.Helper()
	stubUsers := make(map[string]stubUser, len(users))
	for sub, userID := range users {
		stubUsers[sub] = stubUser{UserID: userID}
	}
	return newOrgFixtureWithEmails(t, stubUsers)
}

// newOrgFixtureWithEmails is newOrgFixture's #27 counterpart: identical
// wiring, but the stub identity server also returns each user's email, which
// the accept-on-login path (invitations_test.go) needs.
func newOrgFixtureWithEmails(t *testing.T, users map[string]stubUser) *orgFixture {
	t.Helper()
	return newOrgFixtureInternal(t, users, nil)
}

// tokenClaim is the JWT-level email/email_verified pair a test controls,
// deliberately independent of stubUser.Email (the identity.users profile
// field the internal resolve response carries). The security regression
// test in invitations_test.go needs to set these differently from the
// profile email to prove getMyOrganization matches invitations against the
// verified token claim, never the mutable profile field.
type tokenClaim struct {
	Email         string
	EmailVerified bool
}

// newOrgFixtureWithEmailClaims is newOrgFixtureWithEmails' security-test
// counterpart: users carries the identity.users profile email (mutable,
// PATCH /v1/profile, #25) per stubUser.Email, while claimsBySub carries the
// JWT-verified email/email_verified pair per sub — independently, so a test
// can make them disagree and assert only the verified claim is honored.
func newOrgFixtureWithEmailClaims(t *testing.T, users map[string]stubUser, claimsBySub map[string]tokenClaim) *orgFixture {
	t.Helper()
	return newOrgFixtureInternal(t, users, claimsBySub)
}

// newOrgFixtureInternal is the one shared constructor behind newOrgFixture,
// newOrgFixtureWithEmails and newOrgFixtureWithEmailClaims. When
// claimsBySub is non-nil, the mounted authn chain is wrapped with a layer
// that enriches the verified Claims with a per-sub Email/EmailVerified pair,
// standing in for what a real OIDC token's email/email_verified claims
// would carry — authtest.Mint (services/servicetemplate/authn/authtest,
// shared infra outside this branch's ownership) only sets the standard
// sub/aud/exp claims, so this is the sanctioned test-only seam, mirroring
// services/apiaries/main_test.go and services/sync/main_test.go's own
// injectClaims (which also layers directly on authn.Claims rather than
// extending authtest).
func newOrgFixtureInternal(t *testing.T, users map[string]stubUser, claimsBySub map[string]tokenClaim) *orgFixture {
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
	if claimsBySub != nil {
		authnMW = withEmailClaims(authnMW, claimsBySub)
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

	return &orgFixture{srv: srv, idp: idp, identity: identity, pool: pool}
}

// auditRow is the subset of organizations.audit_log columns (#165,
// history.md §3) the history tests assert on — mirrors
// services/apiaries/main_test.go's own auditRow/auditLogFor.
type auditRow struct {
	EntityType    string
	ChangeType    string
	ActorUserID   string
	OccurredAt    time.Time
	RecordedAt    time.Time
	ChangedFields []string
	Change        json.RawMessage
}

// auditLogFor returns every organizations.audit_log row for one entity,
// oldest first — the same ordering ListAuditLog uses.
func (f *orgFixture) auditLogFor(t *testing.T, entityType, entityID string) []auditRow {
	t.Helper()
	rows, err := f.pool.Query(context.Background(),
		`SELECT entity_type, change_type, actor_user_id, occurred_at, recorded_at, changed_fields, change
		 FROM organizations.audit_log
		 WHERE entity_type = $1 AND entity_id = $2
		 ORDER BY recorded_at, id`, entityType, entityID)
	if err != nil {
		t.Fatalf("query audit_log: %v", err)
	}
	defer rows.Close()

	var out []auditRow
	for rows.Next() {
		var (
			a       auditRow
			actorID uuid.UUID
		)
		if err := rows.Scan(&a.EntityType, &a.ChangeType, &actorID, &a.OccurredAt, &a.RecordedAt, &a.ChangedFields, &a.Change); err != nil {
			t.Fatalf("scan audit_log row: %v", err)
		}
		a.ActorUserID = actorID.String()
		out = append(out, a)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("iterate audit_log: %v", err)
	}
	return out
}

// withEmailClaims wraps authnMW with a layer that overrides the verified
// Claims' Email/EmailVerified per-sub, after real JWT signature/issuer/
// audience verification has already populated Claims from the token's
// standard claims — see newOrgFixtureInternal's doc comment.
func withEmailClaims(authnMW func(http.Handler) http.Handler, claimsBySub map[string]tokenClaim) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return authnMW(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims, ok := authn.FromContext(r.Context())
			if !ok {
				next.ServeHTTP(w, r)
				return
			}
			if tc, found := claimsBySub[claims.Sub]; found {
				claims.Email = tc.Email
				claims.EmailVerified = tc.EmailVerified
			}
			ctx := authn.ContextWithClaims(r.Context(), claims)
			next.ServeHTTP(w, r.WithContext(ctx))
		}))
	}
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
	if org.Role != "admin" {
		t.Errorf("POST /organizations role = %q, want %q (D-3, #172)", org.Role, "admin")
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
	if me.Role != "admin" {
		t.Errorf("GET /organizations/me role = %q, want %q (#172)", me.Role, "admin")
	}

	// GET /organizations/{orgId} for the caller's own org succeeds too.
	recByID := f.do(t, http.MethodGet, "/v1/organizations/"+orgID, bearer, nil)
	if recByID.Code != http.StatusOK {
		t.Fatalf("GET /organizations/%s status = %d, want 200, body = %s", orgID, recByID.Code, recByID.Body.String())
	}
	var byID api.OrganizationResponse
	if err := json.Unmarshal(recByID.Body.Bytes(), &byID); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if byID.Role != "admin" {
		t.Errorf("GET /organizations/%s role = %q, want %q (#172)", orgID, byID.Role, "admin")
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

// TestCreateOrganization_CallerAlreadyHasOrg_Returns409 covers the
// single-org-per-user invariant (C-1): a caller who already has an active
// membership (from an earlier create) cannot create a second organization —
// the client router gate keeps the normal UI path away from this, but a
// direct API call must still be rejected rather than silently giving the
// caller two active memberships (#26 follow-up flagged during #27 review).
func TestCreateOrganization_CallerAlreadyHasOrg_Returns409(t *testing.T) {
	sub := "99999999-9999-4999-8999-999999999999"
	f := newOrgFixture(t, map[string]string{sub: "a0000000-0000-7000-8000-000000000009"})
	bearer := f.token(t, sub)

	first := f.do(t, http.MethodPost, "/v1/organizations", bearer, map[string]string{
		"id": "b0000000-0000-7000-8000-000000000009", "name": "First Org",
	})
	if first.Code != http.StatusCreated {
		t.Fatalf("first POST status = %d, want 201, body = %s", first.Code, first.Body.String())
	}

	second := f.do(t, http.MethodPost, "/v1/organizations", bearer, map[string]string{
		"id": "b0000000-0000-7000-8000-00000000000a", "name": "Second Org",
	})
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

// TestCreateOrganization_History_WritesOrgAndMembershipAuditRowsInSameTx is
// #165's core AC for organization creation: D-3 creates the org and the
// creator's admin membership in one transaction, and this asserts BOTH now
// also get their own organizations.audit_log "create" row, mirroring
// apiaries' #59 TestApiariesSlice_History_CreateUpdateDeleteEachProduceOneAuditRow.
func TestCreateOrganization_History_WritesOrgAndMembershipAuditRowsInSameTx(t *testing.T) {
	sub := "e1111111-1111-4111-8111-1111111111e1"
	userID := "a0000000-0000-7000-8000-0000000000e1"
	f := newOrgFixture(t, map[string]string{sub: userID})
	bearer := f.token(t, sub)
	orgID := "b0000000-0000-7000-8000-0000000000e1"
	before := time.Now().Add(-time.Second)

	rec := f.do(t, http.MethodPost, "/v1/organizations", bearer, map[string]string{
		"id": orgID, "name": "History Co.", "address": "Serra Norte",
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("POST status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	// The organization's own create row.
	orgRows := f.auditLogFor(t, "organization", orgID)
	if len(orgRows) != 1 {
		t.Fatalf("organization audit rows = %d, want 1: %+v", len(orgRows), orgRows)
	}
	orgRow := orgRows[0]
	if orgRow.ChangeType != "create" {
		t.Fatalf("organization audit change_type = %q, want create", orgRow.ChangeType)
	}
	if orgRow.ActorUserID != userID {
		t.Fatalf("organization audit actor_user_id = %q, want %q", orgRow.ActorUserID, userID)
	}
	if orgRow.RecordedAt.Before(before) || orgRow.RecordedAt.After(time.Now().Add(time.Second)) {
		t.Fatalf("organization audit recorded_at = %v, want close to server now", orgRow.RecordedAt)
	}
	if orgRow.ChangedFields != nil {
		t.Fatalf("organization audit changed_fields = %v, want nil (create carries a baseline)", orgRow.ChangedFields)
	}
	var orgChange map[string]any
	if err := json.Unmarshal(orgRow.Change, &orgChange); err != nil {
		t.Fatalf("unmarshal organization change: %v", err)
	}
	if orgChange["name"] != "History Co." || orgChange["address"] != "Serra Norte" {
		t.Fatalf("organization change = %+v, want the baseline name/address", orgChange)
	}

	// The creator's admin membership gets its OWN create row too (a second
	// entity created in the same D-3 transaction).
	var org api.OrganizationResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &org); err != nil {
		t.Fatalf("decode: %v", err)
	}
	recMembers := f.do(t, http.MethodGet, "/v1/organizations/"+orgID+"/members", bearer, nil)
	var members struct {
		Data []api.MemberResponse `json:"data"`
	}
	if err := json.Unmarshal(recMembers.Body.Bytes(), &members); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(members.Data) != 1 {
		t.Fatalf("members = %+v, want exactly 1 (the creator)", members.Data)
	}

	// The membership's audit entity_id isn't returned by any response body,
	// so query by organization_id+entity_type=membership directly instead of
	// by a specific entity_id (mirrors the member list's own lack of a
	// membership id in MemberResponse).
	var membershipRows []auditRow
	rows, err := f.pool.Query(context.Background(),
		`SELECT entity_type, change_type, actor_user_id, occurred_at, recorded_at, changed_fields, change
		 FROM organizations.audit_log
		 WHERE organization_id = $1 AND entity_type = 'membership'
		 ORDER BY recorded_at, id`, orgID)
	if err != nil {
		t.Fatalf("query membership audit_log: %v", err)
	}
	defer rows.Close()
	for rows.Next() {
		var (
			a       auditRow
			actorID uuid.UUID
		)
		if err := rows.Scan(&a.EntityType, &a.ChangeType, &actorID, &a.OccurredAt, &a.RecordedAt, &a.ChangedFields, &a.Change); err != nil {
			t.Fatalf("scan membership audit row: %v", err)
		}
		a.ActorUserID = actorID.String()
		membershipRows = append(membershipRows, a)
	}
	if len(membershipRows) != 1 {
		t.Fatalf("membership audit rows = %d, want 1: %+v", len(membershipRows), membershipRows)
	}
	membershipRow := membershipRows[0]
	if membershipRow.ChangeType != "create" {
		t.Fatalf("membership audit change_type = %q, want create", membershipRow.ChangeType)
	}
	var membershipChange map[string]any
	if err := json.Unmarshal(membershipRow.Change, &membershipChange); err != nil {
		t.Fatalf("unmarshal membership change: %v", err)
	}
	if membershipChange["user_id"] != userID || membershipChange["role"] != "admin" || membershipChange["status"] != "active" {
		t.Fatalf("membership change = %+v, want user_id=%s role=admin status=active", membershipChange, userID)
	}
}

// TestCreateOrganization_History_ChangePayloadNeverEmbedsActorPersonalData is
// #165's pseudonymity contract test (history.md §7.3) for organizations,
// mirroring apiaries' #59
// TestApiariesSlice_History_ChangePayloadNeverEmbedsPersonalData: the actor's
// identity must live solely in actor_user_id, never a denormalized
// actor_name/email field in the change JSONB.
func TestCreateOrganization_History_ChangePayloadNeverEmbedsActorPersonalData(t *testing.T) {
	sub := "e2222222-2222-4222-8222-2222222222e2"
	userID := "a0000000-0000-7000-8000-0000000000e2"
	f := newOrgFixture(t, map[string]string{sub: userID})
	bearer := f.token(t, sub)
	orgID := "b0000000-0000-7000-8000-0000000000e2"

	if rec := f.do(t, http.MethodPost, "/v1/organizations", bearer, map[string]string{
		"id": orgID, "name": "Pseudonymity Co.",
	}); rec.Code != http.StatusCreated {
		t.Fatalf("POST status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	for _, row := range f.auditLogFor(t, "organization", orgID) {
		var decoded map[string]any
		if err := json.Unmarshal(row.Change, &decoded); err != nil {
			t.Fatalf("change payload is not a JSON object: %s", string(row.Change))
		}
		if _, ok := decoded["actor_name"]; ok {
			t.Fatalf("change payload embeds an actor_name field: %s", string(row.Change))
		}
		if _, ok := decoded["actor_email"]; ok {
			t.Fatalf("change payload embeds an actor_email field: %s", string(row.Change))
		}
		if _, ok := decoded["email"]; ok {
			// organizations have no email field of their own — any "email"
			// key here would have to be a leaked actor/member address.
			t.Fatalf("change payload unexpectedly embeds an email field: %s", string(row.Change))
		}
	}
}
