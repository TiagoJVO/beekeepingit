package main

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/config"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/contracttest"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/health"
	"github.com/TiagoJVO/beekeepingit/services/shared/devseed"
	"github.com/TiagoJVO/beekeepingit/services/sync/api"
	"github.com/TiagoJVO/beekeepingit/services/sync/token"
)

// injectClaims stands in for the authn + org-resolver chain (mirrors
// services/apiaries/main_test.go) so these tests drive the handlers directly
// with a known org/user, no live IdP needed.
func injectClaims(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx := authn.ContextWithClaims(r.Context(), authn.Claims{
			Sub:            devseed.OidcSub,
			UserID:         devseed.UserID,
			OrganizationID: devseed.OrganizationID,
			Role:           devseed.MembershipRole,
		})
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// stubApiaries stands in for the owning service the coordinator calls
// (services/sync/api/coordinator_test.go uses the same shape); this test
// only cares about the sync service's own client-facing contract, not the
// downstream apiaries behavior, which is already covered there.
type stubApiaries struct {
	server         *httptest.Server
	validateStatus int
	validateBody   string
	applyStatus    int
	applyBody      string
}

func newStubApiaries(t *testing.T) *stubApiaries {
	t.Helper()
	s := &stubApiaries{validateStatus: http.StatusOK, applyStatus: http.StatusOK, applyBody: `{"results":[]}`}
	mux := http.NewServeMux()
	mux.HandleFunc("/internal/sync/validate", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		if s.validateStatus != http.StatusOK {
			w.Header().Set("Content-Type", "application/problem+json")
			w.WriteHeader(s.validateStatus)
			_, _ = w.Write([]byte(s.validateBody))
			return
		}
		w.WriteHeader(s.validateStatus)
	})
	mux.HandleFunc("/internal/sync/apply", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(s.applyStatus)
		_, _ = w.Write([]byte(s.applyBody))
	})
	s.server = httptest.NewServer(mux)
	t.Cleanup(s.server.Close)
	return s
}

// newSyncFixture builds the real sync HTTP server (TokenHandler + BatchHandler,
// wired exactly as main.go's run() does) against a stub owning service, with
// authn/org-resolution replaced by injectClaims.
func newSyncFixture(t *testing.T) (*servicetemplate.Server, *stubApiaries) {
	t.Helper()
	stub := newStubApiaries(t)
	coord, err := api.NewCoordinator(stub.server.URL, stub.server.URL, stub.server.URL)
	if err != nil {
		t.Fatalf("NewCoordinator: %v", err)
	}

	priv, _, err := token.LoadOrGenerateKey("")
	if err != nil {
		t.Fatalf("LoadOrGenerateKey: %v", err)
	}
	minter, err := token.NewMinter(priv, "https://issuer.test/realms/beekeepingit", "beekeepingit-test", 5*time.Minute)
	if err != nil {
		t.Fatalf("NewMinter: %v", err)
	}

	cfg := config.Config{ServiceName: "sync-test", HTTPAddr: ":0", LogLevel: slog.LevelInfo}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	srv, err := servicetemplate.New(cfg, nil, logger, health.NewRegistry())
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	srv.Router().Group(func(r chi.Router) {
		r.Use(injectClaims)
		r.Get("/v1/sync/token", api.TokenHandler(minter))
		r.Post("/v1/sync/batch", api.BatchHandler(coord))
	})

	return srv, stub
}

func doSync(srv *servicetemplate.Server, method, path, body string) *httptest.ResponseRecorder {
	var r io.Reader
	if body != "" {
		r = strings.NewReader(body)
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(method, path, r)
	srv.Router().ServeHTTP(rec, req)
	return rec
}

// TestSyncSlice_ResponsesConformToOpenAPIContract exercises the sync
// service's client-facing surface (GET /v1/sync/token, POST /v1/sync/batch)
// through the real server and validates each response against
// contracts/openapi/sync — the "contract tests at boundaries" AC of #153,
// extended from services/apiaries to this second real client-facing service.
func TestSyncSlice_ResponsesConformToOpenAPIContract(t *testing.T) {
	doc, err := contracttest.Load("../../contracts/openapi/sync.openapi.yaml")
	if err != nil {
		t.Fatalf("load contract: %v", err)
	}
	srv, stub := newSyncFixture(t)

	recToken := doSync(srv, http.MethodGet, "/v1/sync/token", "")
	if recToken.Code != http.StatusOK {
		t.Fatalf("token status = %d, want 200, body = %s", recToken.Code, recToken.Body.String())
	}
	doc.ValidateResponseBody(t, http.MethodGet, "/v1/sync/token", http.StatusOK, recToken.Body.Bytes())

	batchBody := `{"ops":[{"op":"put","entity_type":"apiary","id":"11111111-1111-4111-8111-111111111111","data":{"name":"x"},"updated_at":"2026-01-01T00:00:00Z"}]}`

	stub.applyBody = `{"results":[{"id":"11111111-1111-4111-8111-111111111111","op":"put","result":"applied"}]}`
	recBatch := doSync(srv, http.MethodPost, "/v1/sync/batch", batchBody)
	if recBatch.Code != http.StatusOK {
		t.Fatalf("batch status = %d, want 200, body = %s", recBatch.Code, recBatch.Body.String())
	}
	doc.ValidateResponseBody(t, http.MethodPost, "/v1/sync/batch", http.StatusOK, recBatch.Body.Bytes())

	// A rejected batch relays the owning service's 422 Problem unchanged.
	stub.validateStatus = http.StatusUnprocessableEntity
	stub.validateBody = `{"title":"Validation failed","status":422,"code":"validation.failed"}`
	recReject := doSync(srv, http.MethodPost, "/v1/sync/batch", batchBody)
	if recReject.Code != http.StatusUnprocessableEntity {
		t.Fatalf("batch-reject status = %d, want 422, body = %s", recReject.Code, recReject.Body.String())
	}
	doc.ValidateResponseBody(t, http.MethodPost, "/v1/sync/batch", http.StatusUnprocessableEntity, recReject.Body.Bytes())
}

// TestLoadEnv_RequiresInternalTodosUrl proves loadEnv treats
// INTERNAL_TODOS_URL as required (#50, mirroring the existing
// INTERNAL_ACTIVITIES_URL requirement it was added alongside) — the
// coordinator can't route "todo" ops to a service it was never told the
// address of.
func TestLoadEnv_RequiresInternalTodosUrl(t *testing.T) {
	t.Setenv("SERVICE_NAME", "sync-test")
	t.Setenv("OIDC_ISSUER_URL", "https://issuer.test/realms/beekeepingit")
	t.Setenv("OIDC_AUDIENCE", "beekeepingit-test")
	t.Setenv("INTERNAL_IDENTITY_URL", "http://identity:8080")
	t.Setenv("INTERNAL_ORGANIZATIONS_URL", "http://organizations:8080")
	t.Setenv("INTERNAL_APIARIES_URL", "http://apiaries:8080")
	t.Setenv("INTERNAL_ACTIVITIES_URL", "http://activities:8080")
	t.Setenv("SYNC_TOKEN_ISSUER", "https://issuer.test/realms/beekeepingit")
	t.Setenv("SYNC_TOKEN_AUDIENCE", "beekeepingit-test")
	// Deliberately NOT setting INTERNAL_TODOS_URL.

	if _, err := loadEnv(); err == nil {
		t.Fatalf("loadEnv succeeded without INTERNAL_TODOS_URL, want an error")
	} else if !strings.Contains(err.Error(), "INTERNAL_TODOS_URL") {
		t.Fatalf("loadEnv error = %v, want it to mention INTERNAL_TODOS_URL", err)
	}

	t.Setenv("INTERNAL_TODOS_URL", "http://todos:8080")
	e, err := loadEnv()
	if err != nil {
		t.Fatalf("loadEnv with INTERNAL_TODOS_URL set: %v", err)
	}
	if e.todosURL != "http://todos:8080" {
		t.Fatalf("e.todosURL = %q, want %q", e.todosURL, "http://todos:8080")
	}
}
