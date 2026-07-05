// Package health provides a Checker registry backing a service's /healthz
// (liveness) and /readyz (readiness) endpoints.
package health

import (
	"context"
	"encoding/json"
	"net/http"
	"sort"
	"sync"
	"time"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

// Checker reports whether a dependency (e.g. the DB pool) is healthy.
type Checker func(ctx context.Context) error

// Registry holds the named Checkers a service's readiness depends on.
type Registry struct {
	mu       sync.RWMutex
	checkers map[string]Checker
}

// NewRegistry returns an empty Registry.
func NewRegistry() *Registry {
	return &Registry{checkers: make(map[string]Checker)}
}

// Register adds (or replaces) a named Checker.
func (r *Registry) Register(name string, c Checker) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.checkers[name] = c
}

// Healthz reports liveness: the process is up and serving. It never runs
// dependency Checkers, so a struggling downstream dependency alone never
// causes an otherwise-healthy process to be killed and restarted.
func (r *Registry) Healthz() http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
	}
}

// Readyz reports readiness: every registered Checker must succeed within a
// bounded timeout. On failure it responds 503 as a problem.Problem naming
// each failing check, so an operator can see why without digging into logs.
func (r *Registry) Readyz() http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		r.mu.RLock()
		checkers := make(map[string]Checker, len(r.checkers))
		for name, c := range r.checkers {
			checkers[name] = c
		}
		r.mu.RUnlock()

		ctx, cancel := context.WithTimeout(req.Context(), 5*time.Second)
		defer cancel()

		var failures []problem.FieldError
		for name, c := range checkers {
			if err := c(ctx); err != nil {
				failures = append(failures, problem.FieldError{Field: name, Code: "check_failed", Message: err.Error()})
			}
		}

		if len(failures) == 0 {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
			return
		}

		sort.Slice(failures, func(i, j int) bool { return failures[i].Field < failures[j].Field })
		problem.Write(w, req, problem.Problem{
			Title:  "Service Unavailable",
			Status: http.StatusServiceUnavailable,
			Detail: "one or more readiness checks failed",
			Code:   "service.not_ready",
			Errors: failures,
		})
	}
}
