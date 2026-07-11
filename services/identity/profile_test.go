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
	srv  *servicetemplate.Server
	idp  *authtest.IDP
	pool *pgxpool.Pool
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

	return &profileFixture{srv: srv, idp: idp, pool: pool}
}

// auditRow is the subset of identity.audit_log columns (#165, history.md §3)
// the history tests below assert on — mirrors services/apiaries/main_test.go's
// own auditRow/auditLogFor.
type auditRow struct {
	ChangeType    string
	ActorUserID   string
	OccurredAt    time.Time
	RecordedAt    time.Time
	ChangedFields []string
	Change        json.RawMessage
}

// auditLogFor returns every identity.audit_log row for one profile, oldest
// first — the same ordering ListAuditLog uses.
func (f *profileFixture) auditLogFor(t *testing.T, entityID string) []auditRow {
	t.Helper()
	rows, err := f.pool.Query(context.Background(),
		`SELECT change_type, actor_user_id, occurred_at, recorded_at, changed_fields, change
		 FROM identity.audit_log
		 WHERE entity_type = 'profile' AND entity_id = $1
		 ORDER BY recorded_at, id`, entityID)
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
		if err := rows.Scan(&a.ChangeType, &actorID, &a.OccurredAt, &a.RecordedAt, &a.ChangedFields, &a.Change); err != nil {
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

// TestProfile_History_CreateThenUpdateEachProduceOneAuditRow is #165's core
// AC for identity: the first GET (create-on-first-seen) and a later PATCH
// each write exactly one correctly attributed identity.audit_log row
// (history.md §3-§4), mirroring apiaries' #59
// TestApiariesSlice_History_CreateUpdateDeleteEachProduceOneAuditRow. Unlike
// apiaries, identity.audit_log.organization_id is always NULL (identity.users
// is global, history.md §9) and occurred_at is server time (no client-device
// timestamp exists on this synchronous API path).
func TestProfile_History_CreateThenUpdateEachProduceOneAuditRow(t *testing.T) {
	f := newProfileFixture(t)
	sub := "aaaaaaaa-1111-4aaa-8aaa-aaaaaaaaaaaa"
	bearer := f.token(t, sub)
	before := time.Now().Add(-time.Second)

	// First GET creates the row.
	recGet := f.do(t, http.MethodGet, "/v1/profile", bearer, nil)
	if recGet.Code != http.StatusOK {
		t.Fatalf("GET status = %d, want 200, body = %s", recGet.Code, recGet.Body.String())
	}
	var p api.ProfileResponse
	if err := json.Unmarshal(recGet.Body.Bytes(), &p); err != nil {
		t.Fatalf("decode: %v", err)
	}

	rows := f.auditLogFor(t, p.ID)
	if len(rows) != 1 {
		t.Fatalf("audit rows after first GET = %d, want 1: %+v", len(rows), rows)
	}
	create := rows[0]
	if create.ChangeType != "create" {
		t.Fatalf("create audit change_type = %q, want create", create.ChangeType)
	}
	if create.ActorUserID != p.ID {
		t.Fatalf("create audit actor_user_id = %q, want %q (self-caused)", create.ActorUserID, p.ID)
	}
	if create.RecordedAt.Before(before) || create.RecordedAt.After(time.Now().Add(time.Second)) {
		t.Fatalf("create audit recorded_at = %v, want close to server now (%v)", create.RecordedAt, before)
	}
	if !create.OccurredAt.Equal(create.RecordedAt) && create.OccurredAt.Before(before) {
		t.Fatalf("create audit occurred_at = %v, want close to server now (%v)", create.OccurredAt, before)
	}
	if create.ChangedFields != nil {
		t.Fatalf("create audit changed_fields = %v, want nil (create carries a baseline, not a diff)", create.ChangedFields)
	}
	var createChange map[string]any
	if err := json.Unmarshal(create.Change, &createChange); err != nil {
		t.Fatalf("unmarshal create change: %v", err)
	}
	if createChange["name"] != "" || createChange["email"] != "" {
		t.Fatalf("create change = %+v, want the baseline (empty name/email for a brand-new profile)", createChange)
	}

	// A second GET (re-seen, not first-seen) must NOT write a second create
	// row — mirrors apiaries' idempotency AC (history.md §4).
	f.do(t, http.MethodGet, "/v1/profile", bearer, nil)
	if n := len(f.auditLogFor(t, p.ID)); n != 1 {
		t.Fatalf("audit rows after second GET = %d, want unchanged 1 (re-GET is not a new change)", n)
	}

	// PATCH (update) writes exactly one more row, a diff of only the changed
	// fields.
	recPatch := f.do(t, http.MethodPatch, "/v1/profile", bearer, map[string]string{
		"name": "Ana Silva", "email": "ana@example.com",
	})
	if recPatch.Code != http.StatusOK {
		t.Fatalf("PATCH status = %d, want 200, body = %s", recPatch.Code, recPatch.Body.String())
	}

	rows = f.auditLogFor(t, p.ID)
	if len(rows) != 2 {
		t.Fatalf("audit rows after PATCH = %d, want 2: %+v", len(rows), rows)
	}
	update := rows[1]
	if update.ChangeType != "update" {
		t.Fatalf("update audit change_type = %q, want update", update.ChangeType)
	}
	wantFields := map[string]bool{"name": true, "email": true}
	if len(update.ChangedFields) != len(wantFields) {
		t.Fatalf("update audit changed_fields = %v, want name and email", update.ChangedFields)
	}
	for _, field := range update.ChangedFields {
		if !wantFields[field] {
			t.Fatalf("update audit changed_fields = %v, want only name/email", update.ChangedFields)
		}
	}
	var updateChange map[string]any
	if err := json.Unmarshal(update.Change, &updateChange); err != nil {
		t.Fatalf("unmarshal update change: %v", err)
	}
	nameDelta, ok := updateChange["name"].(map[string]any)
	if !ok {
		t.Fatalf("update change[name] = %#v, want a {from,to} object", updateChange["name"])
	}
	if nameDelta["from"] != "" || nameDelta["to"] != "Ana Silva" {
		t.Fatalf("update change[name] = %+v, want from=\"\" to=\"Ana Silva\"", nameDelta)
	}
	if _, ok := updateChange["locale"]; ok {
		t.Fatalf("update change unexpectedly contains unchanged field locale: %+v", updateChange)
	}
}

// TestProfile_History_PartialPatchOnlyRecordsChangedFields covers a
// locale-only PATCH: the audit row's changed_fields/change must mention only
// locale, not the untouched name/email.
func TestProfile_History_PartialPatchOnlyRecordsChangedFields(t *testing.T) {
	f := newProfileFixture(t)
	sub := "bbbbbbbb-2222-4bbb-8bbb-bbbbbbbbbbbb"
	bearer := f.token(t, sub)

	recGet := f.do(t, http.MethodGet, "/v1/profile", bearer, nil)
	var p api.ProfileResponse
	if err := json.Unmarshal(recGet.Body.Bytes(), &p); err != nil {
		t.Fatalf("decode: %v", err)
	}
	f.do(t, http.MethodPatch, "/v1/profile", bearer, map[string]string{
		"name": "Beatriz", "email": "bea@example.com",
	})

	rec := f.do(t, http.MethodPatch, "/v1/profile", bearer, map[string]string{"locale": "pt"})
	if rec.Code != http.StatusOK {
		t.Fatalf("locale-only PATCH status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	rows := f.auditLogFor(t, p.ID)
	if len(rows) != 3 {
		t.Fatalf("audit rows = %d, want 3 (create, name/email update, locale update): %+v", len(rows), rows)
	}
	localeUpdate := rows[2]
	if len(localeUpdate.ChangedFields) != 1 || localeUpdate.ChangedFields[0] != "locale" {
		t.Fatalf("locale-only PATCH audit changed_fields = %v, want [locale]", localeUpdate.ChangedFields)
	}
	var change map[string]any
	if err := json.Unmarshal(localeUpdate.Change, &change); err != nil {
		t.Fatalf("unmarshal change: %v", err)
	}
	if _, ok := change["name"]; ok {
		t.Fatalf("locale-only PATCH change unexpectedly contains name: %+v", change)
	}
	if _, ok := change["email"]; ok {
		t.Fatalf("locale-only PATCH change unexpectedly contains email: %+v", change)
	}
}

// TestProfile_History_ChangePayloadNeverEmbedsPersonalDataOfOthers is #165's
// pseudonymity contract test (history.md §7.3), mirroring apiaries' #59
// TestApiariesSlice_ChangePayloadNeverEmbedsPersonalData: a profile's own
// name/email ARE the entity's own subject data (exactly like an apiary's own
// `name`), so they legitimately appear in identity.audit_log.change — what
// must NEVER appear is a distinguishable actor_name/email KEY (the audit
// row's actor identity must live solely in the opaque actor_user_id column,
// never spelled out as a labeled field in the JSONB payload).
func TestProfile_History_ChangePayloadNeverEmbedsPersonalDataOfOthers(t *testing.T) {
	f := newProfileFixture(t)
	sub := "cccccccc-3333-4ccc-8ccc-cccccccccccc"
	bearer := f.token(t, sub)

	recGet := f.do(t, http.MethodGet, "/v1/profile", bearer, nil)
	var p api.ProfileResponse
	if err := json.Unmarshal(recGet.Body.Bytes(), &p); err != nil {
		t.Fatalf("decode: %v", err)
	}
	f.do(t, http.MethodPatch, "/v1/profile", bearer, map[string]string{
		"name": "Carlos Mendes", "email": "carlos.mendes@example.com",
	})

	for _, row := range f.auditLogFor(t, p.ID) {
		var decoded map[string]any
		if err := json.Unmarshal(row.Change, &decoded); err != nil {
			t.Fatalf("change payload is not a JSON object: %s", string(row.Change))
		}
		// The actor identity must never be spelled out as a labeled
		// actor_name/actor_email field — it lives solely in actor_user_id.
		if _, ok := decoded["actor_name"]; ok {
			t.Fatalf("change payload embeds an actor_name field: %s", string(row.Change))
		}
		if _, ok := decoded["actor_email"]; ok {
			t.Fatalf("change payload embeds an actor_email field: %s", string(row.Change))
		}
		// No other user's PII should ever appear (this test's caller is the
		// only "person" involved, but the shape check stands regardless of
		// entity: strings must only ever appear under the known field keys
		// name/email/locale, or nested from/to, never a synthesized "profile
		// of someone else" blob).
		for k := range decoded {
			switch v := decoded[k].(type) {
			case map[string]any:
				for kk := range v {
					if kk != "from" && kk != "to" {
						t.Fatalf("change payload field %q has unexpected nested key %q: %s", k, kk, string(row.Change))
					}
				}
			case string, bool, nil:
				// name/email/locale baseline values or a from/to leaf — fine.
			default:
				t.Fatalf("change payload field %q has unexpected value type %T: %s", k, v, string(row.Change))
			}
		}
	}
}

// TestProfile_History_UnknownSubReturns404WithoutWritingAudit covers a PATCH
// with no prior GET (no profile row yet) — verified to be the intentional
// 404 branch, and confirms it writes no audit row (nothing was actually
// changed).
func TestProfile_History_UnknownSubReturns404WithoutWritingAudit(t *testing.T) {
	f := newProfileFixture(t)
	sub := "dddddddd-4444-4ddd-8ddd-dddddddddddd"
	bearer := f.token(t, sub)

	rec := f.do(t, http.MethodPatch, "/v1/profile", bearer, map[string]string{"name": "Ghost"})
	if rec.Code != http.StatusNotFound {
		t.Fatalf("PATCH-before-GET status = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}

	// There is no known profile id to query by (the row was never created),
	// so assert the table has zero rows for this test's isolated fixture
	// instead of a specific entity_id.
	var n int
	if err := f.pool.QueryRow(context.Background(), "SELECT count(*) FROM identity.audit_log").Scan(&n); err != nil {
		t.Fatalf("count audit_log: %v", err)
	}
	if n != 0 {
		t.Fatalf("audit_log rows = %d, want 0 (no profile was ever created in this fixture)", n)
	}
}
