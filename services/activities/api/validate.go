// Package api (this file) — the thin internal validate endpoint (#38's only
// HTTP surface; mirrors the "apiaries pattern" of a dedicated
// /internal/.../validate route, services/apiaries/api/sync.go's
// validateBatch, kept minimal here on purpose). It runs the same
// ValidateActivity server-side check (types.go) a future create endpoint
// (#39) will run before writing anything, WITHOUT touching the database —
// no row is inserted, no history/tenancy write happens here. Its purpose for
// this issue is to prove, at the HTTP/wire level (not just as a pure-Go unit
// test), that "reject unknown or malformed attributes" (FR-AC-1 AC) actually
// holds end-to-end through the JWT + org-resolver + RFC 9457 stack #39 will
// build the real create endpoint on top of.
package api

import (
	"encoding/json"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

// dateLayout is the wire format for an activity's occurred_at date — plain
// YYYY-MM-DD, matching the DB column's DATE type (no time-of-day component,
// store/migrations/00001_create_activities.sql).
const dateLayout = "2006-01-02"

// maxValidateBodyBytes caps the raw request body for the stateless validate
// endpoint (a single activity payload — a handful of known keys, notes capped
// at maxNotesLength chars), via http.MaxBytesReader, so a client can't force
// an unbounded json.Decode buffer. Mirrors apiaries' maxSyncBatchBodyBytes
// (services/apiaries/api/sync.go).
const maxValidateBodyBytes = 256 << 10 // 256 KiB

// validateRequestBody is the wire shape for POST /internal/activities/validate
// — the same {type, occurred_at, attributes} triple #39's create request will
// eventually carry, but validated only, never persisted.
type validateRequestBody struct {
	Type       string          `json:"type"`
	OccurredAt string          `json:"occurred_at"`
	Attributes json.RawMessage `json:"attributes"`
}

// InternalValidateRouter mounts the validate-only route. Behind
// authn+org-resolver+RequireRole in main.go, matching apiaries' internal
// sync router wiring — the org scope isn't used by validation itself (it's
// stateless), but keeping the middleware chain consistent is exactly what
// lets #39 grow this into a real write endpoint without re-wiring auth.
func InternalValidateRouter() http.Handler {
	r := chi.NewRouter()
	r.Post("/validate", validateHandler())
	return r
}

func validateHandler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if _, _, ok := requireOrg(w, r); !ok {
			return
		}

		r.Body = http.MaxBytesReader(w, r.Body, maxValidateBodyBytes)

		var body validateRequestBody
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			problem.Write(w, r, problem.ValidationFailed("request body must be a valid JSON object",
				problem.FieldError{Field: "(body)", Code: "invalid", Message: "request body must be a valid JSON object"}))
			return
		}

		errs := validateRequestErrors(body)
		if len(errs) > 0 {
			problem.Write(w, r, problem.ValidationFailed("activity payload failed validation", errs...))
			return
		}
		writeJSON(w, r, http.StatusOK, map[string]bool{"valid": true})
	}
}

// validateRequestErrors runs every #38 validation rule against body:
// occurred_at presence/format, and — via ValidateActivity — the selected
// type's own attribute schema (unknown type, unknown/missing/malformed
// attributes). Extracted from validateHandler so it's directly unit-testable
// without an HTTP round trip.
func validateRequestErrors(body validateRequestBody) []problem.FieldError {
	var errs []problem.FieldError

	switch {
	case strings.TrimSpace(body.OccurredAt) == "":
		errs = append(errs, problem.FieldError{Field: "occurred_at", Code: "required", Message: "occurred_at is required"})
	default:
		if _, err := time.Parse(dateLayout, body.OccurredAt); err != nil {
			errs = append(errs, problem.FieldError{Field: "occurred_at", Code: "invalid", Message: "occurred_at must be a YYYY-MM-DD date"})
		}
	}

	// attrsOK is tracked separately from attrs's nil-ness: json.Unmarshal sets
	// a map target to nil (with err == nil) for the literal JSON `null`, so
	// keying the ValidateActivity call off `attrs != nil` would let
	// {"attributes": null} silently skip all per-type validation (including
	// required fields). Treat `null` the same as any other non-object.
	attrs := map[string]any{}
	attrsOK := true
	if len(body.Attributes) > 0 {
		if err := json.Unmarshal(body.Attributes, &attrs); err != nil || attrs == nil {
			errs = append(errs, problem.FieldError{Field: "attributes", Code: "invalid", Message: "attributes must be a JSON object"})
			attrsOK = false
		}
	}

	switch {
	case strings.TrimSpace(body.Type) == "":
		errs = append(errs, problem.FieldError{Field: "type", Code: "required", Message: "type is required"})
	case attrsOK:
		errs = append(errs, ValidateActivity(body.Type, attrs)...)
	}

	sort.Slice(errs, func(i, j int) bool { return errs[i].Field < errs[j].Field })
	return errs
}
