package logging_test

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-chi/chi/v5/middleware"
	"go.opentelemetry.io/otel/log/noop"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/config"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
)

func TestNewLogger_WritesJSONToStdoutAndOTelBridge(t *testing.T) {
	// NewLogger always writes to os.Stdout (kubectl-logs friendliness) and
	// fans out to the OTel bridge — this test just proves construction with
	// a real (no-op) LoggerProvider doesn't panic and yields a usable logger.
	cfg := config.Config{ServiceName: "example", LogLevel: slog.LevelInfo}
	logger := logging.NewLogger(cfg, noop.NewLoggerProvider())
	if logger == nil {
		t.Fatal("NewLogger returned nil")
	}
	logger.Info("smoke test") // must not panic
}

func TestRequestLogger_SetsContextLoggerAndLogsCompletion(t *testing.T) {
	var buf bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&buf, nil))

	var fromCtx *slog.Logger
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fromCtx = logging.FromContext(r.Context())
		w.WriteHeader(http.StatusTeapot)
	})

	handler := middleware.RequestID(logging.RequestLogger(logger)(next))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/example-items", nil)
	handler.ServeHTTP(rec, req)

	if fromCtx == nil {
		t.Fatal("FromContext returned nil inside the handler")
	}

	var got map[string]any
	if err := json.Unmarshal(buf.Bytes(), &got); err != nil {
		t.Fatalf("decode log line: %v", err)
	}
	if got["method"] != http.MethodGet || got["path"] != "/v1/example-items" {
		t.Errorf("log line missing request-scoped fields: %v", got)
	}
	if _, ok := got["request_id"]; !ok {
		t.Errorf("log line missing request_id: %v", got)
	}
	if int(got["status"].(float64)) != http.StatusTeapot {
		t.Errorf("status = %v, want %d", got["status"], http.StatusTeapot)
	}
}

func TestFromContext_DefaultsOutsideRequest(t *testing.T) {
	if logging.FromContext(context.Background()) == nil {
		t.Error("FromContext(background) = nil, want slog.Default()")
	}
}
