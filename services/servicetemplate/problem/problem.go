// Package problem implements RFC 9457 Problem Details for HTTP APIs — the
// single error format every BeekeepingIT service returns, matching the
// Problem schema in contracts/openapi/_shared/components.openapi.yaml.
package problem

import (
	"encoding/json"
	"net/http"
)

// FieldError carries field-level validation detail, used in 422 responses.
type FieldError struct {
	Field   string `json:"field"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

// Problem is an RFC 9457 Problem Details payload.
type Problem struct {
	Type     string       `json:"type,omitempty"` // absent means "about:blank" per RFC 9457
	Title    string       `json:"title"`
	Status   int          `json:"status"`
	Detail   string       `json:"detail,omitempty"`
	Instance string       `json:"instance,omitempty"`
	Code     string       `json:"code,omitempty"`
	Errors   []FieldError `json:"errors,omitempty"`
}

const mediaType = "application/problem+json"

// Write encodes p as the response body with the application/problem+json
// media type and p.Status as the HTTP status code. Instance defaults to the
// request's path when unset.
func Write(w http.ResponseWriter, r *http.Request, p Problem) {
	if p.Instance == "" && r != nil {
		p.Instance = r.URL.Path
	}
	w.Header().Set("Content-Type", mediaType)
	w.WriteHeader(p.Status)
	_ = json.NewEncoder(w).Encode(p)
}

// Canonical constructors, statuses and codes per
// docs/architecture/api-contracts.md §4/§7.

// Unauthorized builds a 401 Problem for a missing, malformed, invalid or
// expired credential (the caller's identity was not established).
func Unauthorized(detail string) Problem {
	return Problem{Title: "Unauthorized", Status: http.StatusUnauthorized, Detail: detail, Code: "auth.unauthorized"}
}

// Forbidden builds a 403 Problem for an authenticated caller whose resolved
// role or organization scope does not permit the requested action.
func Forbidden(detail string) Problem {
	return Problem{Title: "Forbidden", Status: http.StatusForbidden, Detail: detail, Code: "auth.forbidden"}
}

// NotFound builds a 404 Problem for a resource that doesn't exist — or that
// the caller isn't allowed to know exists (e.g. another organization's
// resource; ADR-0002, api-contracts.md §9 prefer 404 over 403 there).
func NotFound(detail string) Problem {
	return Problem{Title: "Not Found", Status: http.StatusNotFound, Detail: detail, Code: "resource.not_found"}
}

// Conflict builds a 409 Problem for a request that conflicts with the
// resource's current state (e.g. a stale ETag / optimistic-concurrency
// mismatch, or a uniqueness constraint violation).
func Conflict(detail string) Problem {
	return Problem{Title: "Conflict", Status: http.StatusConflict, Detail: detail, Code: "resource.conflict"}
}

// ValidationFailed builds a 422 Problem carrying field-level detail.
func ValidationFailed(detail string, errs ...FieldError) Problem {
	return Problem{
		Title:  "Validation failed",
		Status: http.StatusUnprocessableEntity,
		Detail: detail,
		Code:   "validation.failed",
		Errors: errs,
	}
}

// Internal builds a 500 Problem with a fixed, generic detail — it never
// echoes the underlying error back to the client.
func Internal() Problem {
	return Problem{
		Title:  "Internal Server Error",
		Status: http.StatusInternalServerError,
		Detail: "an unexpected error occurred",
		Code:   "internal.error",
	}
}
