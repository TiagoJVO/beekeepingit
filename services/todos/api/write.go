// Package api (this file) — the client-facing REST create/edit/complete/
// reopen/delete routes (#50, FR-TD-1, FR-TEN-2, FR-HIS-1). Mirrors
// services/activities/api/write.go's shape closely (this repo's five domain
// services all wire the same create→edit→delete convention); the one
// genuinely new pattern here is the cross-service assignee_id ownership
// guard (members_client.go), the D-23 counterpart of activities'
// apiary_id guard. Both this REST path and the internal sync path (sync.go)
// write the same todos.todos table and must apply the same validation,
// tenancy and history-recording rules.
//
// #51 (FR-TD-1) adds the optional apiary_id field — a todo may be associated
// with a specific apiary, or left as a general, org-level todo. It follows
// the EXACT SAME full-resubmit convention as assignee_id above (an
// omitted/null apiary_id means "clear/unset", never "leave unchanged") and
// is verified against the apiaries service itself (apiaries_client.go's
// ApiaryVerifier) before every write that sets it, ONLY when the resubmitted
// value is non-empty — clearing it makes no upstream call at all.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
	"github.com/TiagoJVO/beekeepingit/services/shared/history"
	sqlcgen "github.com/TiagoJVO/beekeepingit/services/todos/store/sqlc/gen"
)

// maxCreateBodyBytes caps the raw request body for the write routes below —
// a todo payload is a handful of known keys, description capped at
// maxDescriptionLength chars — via http.MaxBytesReader, mirroring
// activities' write.go's identical cap.
const maxCreateBodyBytes = 256 << 10 // 256 KiB

// maxDescriptionLength bounds the optional free-text description (FR-TD-1) —
// generous for a task note without allowing it to become an unbounded blob.
const maxDescriptionLength = 10000

// maxTitleLength bounds the required title.
const maxTitleLength = 500

// todoCreateRequest is the POST /v1/todos request body. id is client-supplied
// (offline-generatable UUID) — the natural idempotency anchor for a re-sent
// create, matching activities' activityCreateRequest.ID convention.
// assignee_id (D-23) is a CROSS-SERVICE reference (members_client.go's doc
// comment) — verified against the caller's org before anything is written,
// ONLY when present and non-empty; omitted/empty means "unassigned" (D-23's
// default), no verification call made. apiary_id (#51, FR-TD-1) is likewise a
// CROSS-SERVICE reference (apiaries_client.go's doc comment), verified the
// same way, ONLY when present and non-empty; omitted/empty means "a general,
// org-level todo", no verification call made. status is deliberately NOT a
// request field — every new todo starts StatusOpen (FR-TD-1); complete/reopen
// own the status transition exclusively.
type todoCreateRequest struct {
	ID          string  `json:"id"`
	Title       string  `json:"title"`
	Description *string `json:"description"`
	DueDate     *string `json:"due_date"`
	Priority    string  `json:"priority"`
	AssigneeID  *string `json:"assignee_id"`
	ApiaryID    *string `json:"apiary_id"`
}

// todoUpdateRequest is the PATCH /v1/todos/{id} request body — a FULL
// resubmit of title/description/due_date/priority/assignee_id/apiary_id
// (unlike activities' apiary_id, which is optional-and-falls-back on edit,
// D-23's assignee_id — and #51's apiary_id, following the exact same
// convention — are always part of the resubmitted state here: an omitted or
// null assignee_id/apiary_id means "clear it", not "leave unchanged" — see
// updateTodo's own doc comment). status/completed_at are never touched by
// this route; complete()/reopen() below own that transition exclusively.
type todoUpdateRequest struct {
	Title       string  `json:"title"`
	Description *string `json:"description"`
	DueDate     *string `json:"due_date"`
	Priority    string  `json:"priority"`
	AssigneeID  *string `json:"assignee_id"`
	ApiaryID    *string `json:"apiary_id"`
}

// todoDTO is the client-facing todo shape.
type todoDTO struct {
	ID             string     `json:"id"`
	OrganizationID string     `json:"organization_id"`
	Title          string     `json:"title"`
	Description    *string    `json:"description,omitempty"`
	DueDate        *string    `json:"due_date,omitempty"`
	Priority       string     `json:"priority"`
	Status         string     `json:"status"`
	CompletedAt    *time.Time `json:"completed_at,omitempty"`
	AssigneeID     *string    `json:"assignee_id,omitempty"`
	ApiaryID       *string    `json:"apiary_id,omitempty"`
	CreatedAt      time.Time  `json:"created_at"`
	UpdatedAt      time.Time  `json:"updated_at"`
}

// Router returns the client-facing /v1/todos surface: create, edit,
// complete, reopen and delete (#50/FR-TD-1), plus apiary association (#51).
// List/filter (#53) is explicitly out of scope — no GET/list route exists
// yet, mirroring activities' own #38/#39 scope-split precedent (this
// package's earlier stories shipped writes before reads too).
func Router(pool *pgxpool.Pool, verifier *MemberVerifier, apiaryVerifier *ApiaryVerifier) http.Handler {
	r := chi.NewRouter()
	r.Post("/", createTodo(pool, verifier, apiaryVerifier))
	r.Patch("/{todoId}", updateTodo(pool, verifier, apiaryVerifier))
	r.Post("/{todoId}/complete", completeTodo(pool))
	r.Post("/{todoId}/reopen", reopenTodo(pool))
	r.Delete("/{todoId}", deleteTodo(pool))
	return r
}

func createTodo(pool *pgxpool.Pool, verifier *MemberVerifier, apiaryVerifier *ApiaryVerifier) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, userID, ok := requireOrg(w, r)
		if !ok {
			return
		}

		r.Body = http.MaxBytesReader(w, r.Body, maxCreateBodyBytes)
		var body todoCreateRequest
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			problem.Write(w, r, problem.ValidationFailed("request body must be valid JSON"))
			return
		}

		id, title, description, dueDate, priority, assigneeID, apiaryID, fieldErrs := validateTodoCreate(body)
		if len(fieldErrs) > 0 {
			problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid", fieldErrs...))
			return
		}

		// CRITICAL tenancy guard (D-23, mirroring activities' apiary_id
		// carry-over from #284's cross-tenant IDOR fix): assignee_id must
		// belong to the CALLER'S organization, verified via the owning service
		// (members_client.go), BEFORE any row is inserted — ONLY when the
		// request actually carries one (the common case is unassigned).
		if assigneeID != "" {
			belongs, err := verifier.BelongsToOrg(r.Context(), r.Header.Get("Authorization"), uuidString(org), assigneeID)
			if err != nil {
				logging.FromContext(r.Context()).ErrorContext(r.Context(), "verify assignee membership failed", slog.Any("error", err))
				problem.Write(w, r, problem.Internal())
				return
			}
			if !belongs {
				// Unknown/foreign assignee_id — 422, indistinguishable from a
				// truly-unknown user (ADR-0002 scope-hiding, same convention
				// activities' apiary_id guard uses).
				problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid",
					problem.FieldError{Field: "assignee_id", Code: "not_found", Message: "assignee_id does not refer to a member of this organization"}))
				return
			}
		}

		// CRITICAL tenancy guard (#51, mirroring assignee_id above and
		// activities' own apiary_id guard): apiary_id must belong to the
		// CALLER'S organization, verified via the owning service
		// (apiaries_client.go), BEFORE any row is inserted — ONLY when the
		// request actually carries one (the common case is a general,
		// org-level todo).
		if apiaryID != "" {
			belongs, err := apiaryVerifier.BelongsToOrg(r.Context(), r.Header.Get("Authorization"), apiaryID)
			if err != nil {
				logging.FromContext(r.Context()).ErrorContext(r.Context(), "verify apiary ownership failed", slog.Any("error", err))
				problem.Write(w, r, problem.Internal())
				return
			}
			if !belongs {
				// Unknown/foreign apiary_id — 422, indistinguishable from a
				// truly-unknown apiary (ADR-0002 scope-hiding).
				problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid",
					problem.FieldError{Field: "apiary_id", Code: "not_found", Message: "apiary_id does not refer to an apiary of this organization"}))
				return
			}
		}

		dueDateParam, err := dateParam(dueDate) // format already validated
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "parse due_date failed after validation", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}
		assigneeParam, err := uuidParam(assigneeID) // format already validated
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "parse assignee_id failed after validation", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}
		apiaryParam, err := uuidParam(apiaryID) // format already validated
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "parse apiary_id failed after validation", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		now := time.Now().UTC()
		pgID := pgtype.UUID{Bytes: id, Valid: true}

		var row sqlcgen.TodosTodo
		err = withTx(r.Context(), pool, func(q *sqlcgen.Queries) error {
			var err error
			row, err = q.InsertTodo(r.Context(), sqlcgen.InsertTodoParams{
				ID:             pgID,
				OrganizationID: org,
				Title:          title,
				Description:    textParam(description),
				DueDate:        dueDateParam,
				Priority:       priority,
				Status:         StatusOpen,
				AssigneeID:     assigneeParam,
				ApiaryID:       apiaryParam,
				UpdatedAt:      pgtype.Timestamptz{Time: now, Valid: true},
			})
			if isUniqueViolation(err) {
				// Idempotency (the client-generated id is the natural
				// anchor, same convention as activities): a re-sent create
				// with the same id and the same content returns the
				// original result unchanged; a genuinely different payload
				// reusing the same id is a real conflict.
				respondIdempotentCreateOrConflict(r.Context(), w, r, sqlcgen.New(pool), org, id, title, description, dueDate, priority, assigneeID, apiaryID)
				return errResponseWritten
			}
			if err != nil {
				return fmt.Errorf("insert todo: %w", err)
			}

			want := todoRowState{title: title, description: description, dueDate: dueDate, priority: priority, status: StatusOpen, assigneeID: assigneeID, apiaryID: apiaryID}
			if err := writeTodoAuditLogTx(r.Context(), q, org, userID, id, history.ChangeCreate, now, todoRowState{}, want); err != nil {
				return fmt.Errorf("write audit log: %w", err)
			}
			return nil
		})
		if err != nil {
			if !errors.Is(err, errResponseWritten) {
				logging.FromContext(r.Context()).ErrorContext(r.Context(), "create todo failed", slog.Any("error", err))
				problem.Write(w, r, problem.Internal())
			}
			return
		}

		w.Header().Set("Location", "/v1/todos/"+uuidString(row.ID))
		writeJSON(w, r, http.StatusCreated, toTodoDTO(row))
	}
}

// updateTodo handles PATCH /v1/todos/{id} (FR-TD-1): a FULL resubmit of
// title/description/due_date/priority/assignee_id/apiary_id. Re-verifies
// assignee_id/apiary_id via the same cross-service ownership checks
// createTodo uses, but ONLY when the resubmitted value is non-empty
// (todoUpdateRequest's doc comment) — clearing either (omitted/null in the
// request) writes NULL with no upstream call at all. Never touches
// status/completed_at (complete/reopen below own that transition
// exclusively). Records the edit in audit_log (FR-HIS-1).
func updateTodo(pool *pgxpool.Pool, verifier *MemberVerifier, apiaryVerifier *ApiaryVerifier) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, userID, ok := requireOrg(w, r)
		if !ok {
			return
		}
		id, err := uuid.Parse(chi.URLParam(r, "todoId"))
		if err != nil {
			problem.Write(w, r, problem.NotFound("todo not found"))
			return
		}

		r.Body = http.MaxBytesReader(w, r.Body, maxCreateBodyBytes)
		var body todoUpdateRequest
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			problem.Write(w, r, problem.ValidationFailed("request body must be valid JSON"))
			return
		}

		title, description, dueDate, priority, assigneeID, apiaryID, fieldErrs := validateTodoUpdate(body)
		if len(fieldErrs) > 0 {
			problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid", fieldErrs...))
			return
		}

		// Ownership re-verify (CRITICAL, D-23 carry-over from createTodo):
		// only when the resubmitted assignee_id is non-empty — clearing it
		// (the common "unassign" action) makes no cross-service call at all,
		// exactly like sync.go's resolveAssigneeOwnership only resolves
		// assignee_ids that are actually present in a batch op's data.
		if assigneeID != "" {
			belongs, err := verifier.BelongsToOrg(r.Context(), r.Header.Get("Authorization"), uuidString(org), assigneeID)
			if err != nil {
				logging.FromContext(r.Context()).ErrorContext(r.Context(), "verify assignee membership failed", slog.Any("error", err))
				problem.Write(w, r, problem.Internal())
				return
			}
			if !belongs {
				problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid",
					problem.FieldError{Field: "assignee_id", Code: "not_found", Message: "assignee_id does not refer to a member of this organization"}))
				return
			}
		}

		// Ownership re-verify (CRITICAL, #51 carry-over from createTodo):
		// only when the resubmitted apiary_id is non-empty — clearing it (the
		// common "unlink from apiary" action) makes no cross-service call at
		// all, mirroring the assignee_id guard directly above.
		if apiaryID != "" {
			belongs, err := apiaryVerifier.BelongsToOrg(r.Context(), r.Header.Get("Authorization"), apiaryID)
			if err != nil {
				logging.FromContext(r.Context()).ErrorContext(r.Context(), "verify apiary ownership failed", slog.Any("error", err))
				problem.Write(w, r, problem.Internal())
				return
			}
			if !belongs {
				problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid",
					problem.FieldError{Field: "apiary_id", Code: "not_found", Message: "apiary_id does not refer to an apiary of this organization"}))
				return
			}
		}

		pgID := pgtype.UUID{Bytes: id, Valid: true}
		dueDateParam, err := dateParam(dueDate)
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "parse due_date failed after validation", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}
		assigneeParam, err := uuidParam(assigneeID)
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "parse assignee_id failed after validation", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}
		apiaryParam, err := uuidParam(apiaryID)
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "parse apiary_id failed after validation", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		var (
			updated sqlcgen.TodosTodo
			before  todoRowState
			want    todoRowState
		)
		err = withTx(r.Context(), pool, func(q *sqlcgen.Queries) error {
			current, err := q.GetTodoForUpdate(r.Context(), sqlcgen.GetTodoForUpdateParams{OrganizationID: org, ID: pgID})
			if err != nil || current.DeletedAt.Valid {
				problem.Write(w, r, problem.NotFound("todo not found"))
				return errResponseWritten
			}
			before = todoRowStateFromRow(current)
			want = todoRowState{
				title: title, description: description, dueDate: dueDate, priority: priority,
				status: before.status, completedAt: before.completedAt, assigneeID: assigneeID, apiaryID: apiaryID,
			}

			now := time.Now().UTC()
			var updateErr error
			updated, updateErr = q.UpdateTodo(r.Context(), sqlcgen.UpdateTodoParams{
				OrganizationID: org, ID: pgID,
				Title: title, Description: textParam(description), DueDate: dueDateParam,
				Priority: priority, AssigneeID: assigneeParam, ApiaryID: apiaryParam,
				UpdatedAt: pgtype.Timestamptz{Time: now, Valid: true},
			})
			if updateErr != nil {
				return fmt.Errorf("update todo: %w", updateErr)
			}

			if err := writeTodoAuditLogTx(r.Context(), q, org, userID, id, history.ChangeUpdate, now, before, want); err != nil {
				return fmt.Errorf("write audit log: %w", err)
			}
			return nil
		})
		if err != nil {
			if !errors.Is(err, errResponseWritten) {
				logging.FromContext(r.Context()).ErrorContext(r.Context(), "update todo failed", slog.Any("error", err))
				problem.Write(w, r, problem.Internal())
			}
			return
		}

		writeJSON(w, r, http.StatusOK, toTodoDTO(updated))
	}
}

// completeTodo handles POST /v1/todos/{id}/complete (FR-TD-1): sets
// status=done + completed_at=now, recording the transition as an ordinary
// history.ChangeUpdate row (changed_fields will show status/completed_at) —
// no dedicated audit change_type is needed for this lifecycle action.
// Idempotent when already done: a repeat call is a genuine no-op (the
// original completed_at is preserved, not bumped, and no second audit row is
// written) rather than silently "completing it again" with a fresh
// timestamp.
func completeTodo(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, userID, ok := requireOrg(w, r)
		if !ok {
			return
		}
		id, err := uuid.Parse(chi.URLParam(r, "todoId"))
		if err != nil {
			problem.Write(w, r, problem.NotFound("todo not found"))
			return
		}
		pgID := pgtype.UUID{Bytes: id, Valid: true}

		var updated sqlcgen.TodosTodo
		err = withTx(r.Context(), pool, func(q *sqlcgen.Queries) error {
			current, err := q.GetTodoForUpdate(r.Context(), sqlcgen.GetTodoForUpdateParams{OrganizationID: org, ID: pgID})
			if err != nil || current.DeletedAt.Valid {
				problem.Write(w, r, problem.NotFound("todo not found"))
				return errResponseWritten
			}
			if current.Status == StatusDone {
				updated = current // idempotent no-op: already done
				return nil
			}

			before := todoRowStateFromRow(current)
			now := time.Now().UTC()
			var updateErr error
			updated, updateErr = q.CompleteTodo(r.Context(), sqlcgen.CompleteTodoParams{
				OrganizationID: org, ID: pgID, CompletedAt: pgtype.Timestamptz{Time: now, Valid: true},
			})
			if updateErr != nil {
				return fmt.Errorf("complete todo: %w", updateErr)
			}

			want := before
			want.status = StatusDone
			want.completedAt = timestampOf(pgtype.Timestamptz{Time: now, Valid: true})
			if err := writeTodoAuditLogTx(r.Context(), q, org, userID, id, history.ChangeUpdate, now, before, want); err != nil {
				return fmt.Errorf("write audit log: %w", err)
			}
			return nil
		})
		if err != nil {
			if !errors.Is(err, errResponseWritten) {
				logging.FromContext(r.Context()).ErrorContext(r.Context(), "complete todo failed", slog.Any("error", err))
				problem.Write(w, r, problem.Internal())
			}
			return
		}

		writeJSON(w, r, http.StatusOK, toTodoDTO(updated))
	}
}

// reopenTodo handles POST /v1/todos/{id}/reopen (FR-TD-1): sets status=open
// and clears completed_at. Idempotent when already open, mirroring
// completeTodo's own no-op convention.
func reopenTodo(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, userID, ok := requireOrg(w, r)
		if !ok {
			return
		}
		id, err := uuid.Parse(chi.URLParam(r, "todoId"))
		if err != nil {
			problem.Write(w, r, problem.NotFound("todo not found"))
			return
		}
		pgID := pgtype.UUID{Bytes: id, Valid: true}

		var updated sqlcgen.TodosTodo
		err = withTx(r.Context(), pool, func(q *sqlcgen.Queries) error {
			current, err := q.GetTodoForUpdate(r.Context(), sqlcgen.GetTodoForUpdateParams{OrganizationID: org, ID: pgID})
			if err != nil || current.DeletedAt.Valid {
				problem.Write(w, r, problem.NotFound("todo not found"))
				return errResponseWritten
			}
			if current.Status == StatusOpen {
				updated = current // idempotent no-op: already open
				return nil
			}

			before := todoRowStateFromRow(current)
			now := time.Now().UTC()
			var updateErr error
			updated, updateErr = q.ReopenTodo(r.Context(), sqlcgen.ReopenTodoParams{
				OrganizationID: org, ID: pgID, UpdatedAt: pgtype.Timestamptz{Time: now, Valid: true},
			})
			if updateErr != nil {
				return fmt.Errorf("reopen todo: %w", updateErr)
			}

			want := before
			want.status = StatusOpen
			want.completedAt = ""
			if err := writeTodoAuditLogTx(r.Context(), q, org, userID, id, history.ChangeUpdate, now, before, want); err != nil {
				return fmt.Errorf("write audit log: %w", err)
			}
			return nil
		})
		if err != nil {
			if !errors.Is(err, errResponseWritten) {
				logging.FromContext(r.Context()).ErrorContext(r.Context(), "reopen todo failed", slog.Any("error", err))
				problem.Write(w, r, problem.Internal())
			}
			return
		}

		writeJSON(w, r, http.StatusOK, toTodoDTO(updated))
	}
}

// deleteTodo handles DELETE /v1/todos/{id} (FR-TD-1): tombstones the row
// (deleted_at, mirroring activities' deleteActivity) rather than a hard
// delete, so the PowerSync sync rule's `deleted_at IS NULL` filter
// propagates the delete to every device on their next sync. Records the
// delete in audit_log (FR-HIS-1).
func deleteTodo(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, userID, ok := requireOrg(w, r)
		if !ok {
			return
		}
		id, err := uuid.Parse(chi.URLParam(r, "todoId"))
		if err != nil {
			problem.Write(w, r, problem.NotFound("todo not found"))
			return
		}
		pgID := pgtype.UUID{Bytes: id, Valid: true}

		err = withTx(r.Context(), pool, func(q *sqlcgen.Queries) error {
			current, err := q.GetTodoForUpdate(r.Context(), sqlcgen.GetTodoForUpdateParams{OrganizationID: org, ID: pgID})
			if err != nil || current.DeletedAt.Valid {
				problem.Write(w, r, problem.NotFound("todo not found"))
				return errResponseWritten
			}

			now := time.Now().UTC()
			rowsAffected, err := q.SoftDeleteTodo(r.Context(), sqlcgen.SoftDeleteTodoParams{
				OrganizationID: org, ID: pgID, DeletedAt: pgtype.Timestamptz{Time: now, Valid: true},
			})
			if err != nil {
				return fmt.Errorf("soft delete todo: %w", err)
			}
			if rowsAffected == 0 {
				problem.Write(w, r, problem.NotFound("todo not found"))
				return errResponseWritten
			}

			before := todoRowStateFromRow(current)
			if err := writeTodoAuditLogTx(r.Context(), q, org, userID, id, history.ChangeDelete, now, before, todoRowState{}); err != nil {
				return fmt.Errorf("write audit log: %w", err)
			}
			return nil
		})
		if err != nil {
			if !errors.Is(err, errResponseWritten) {
				logging.FromContext(r.Context()).ErrorContext(r.Context(), "delete todo failed", slog.Any("error", err))
				problem.Write(w, r, problem.Internal())
			}
			return
		}

		w.WriteHeader(http.StatusNoContent)
	}
}

// respondIdempotentCreateOrConflict handles createTodo's unique_violation
// branch: the id already exists in this org. Same content ⇒ 201 with the
// existing (unchanged) row; different content, or the id belongs to a
// different org (existing row simply not found under org scope) ⇒ 409.
// Mirrors activities' write.go helper of the same name/shape.
func respondIdempotentCreateOrConflict(ctx context.Context, w http.ResponseWriter, r *http.Request, q *sqlcgen.Queries, org pgtype.UUID, id uuid.UUID, title, description, dueDate, priority, assigneeID, apiaryID string) {
	existing, err := q.GetTodo(ctx, sqlcgen.GetTodoParams{OrganizationID: org, ID: pgtype.UUID{Bytes: id, Valid: true}})
	if err != nil {
		problem.Write(w, r, problem.Conflict("a todo with this id already exists"))
		return
	}
	same := existing.Title == title && textOf(existing.Description) == description &&
		dateOf(existing.DueDate) == dueDate && existing.Priority == priority &&
		uuidOf(existing.AssigneeID) == assigneeID && uuidOf(existing.ApiaryID) == apiaryID
	if !same {
		problem.Write(w, r, problem.Conflict("a todo with this id already exists with different content"))
		return
	}
	writeJSON(w, r, http.StatusCreated, toTodoDTO(existing))
}

func toTodoDTO(row sqlcgen.TodosTodo) todoDTO {
	return todoDTO{
		ID:             uuidString(row.ID),
		OrganizationID: uuidString(row.OrganizationID),
		Title:          row.Title,
		Description:    optStr(textOf(row.Description)),
		DueDate:        optStr(dateOf(row.DueDate)),
		Priority:       row.Priority,
		Status:         row.Status,
		CompletedAt:    timePtr(row.CompletedAt),
		AssigneeID:     optStr(uuidOf(row.AssigneeID)),
		ApiaryID:       optStr(uuidOf(row.ApiaryID)),
		CreatedAt:      row.CreatedAt.Time,
		UpdatedAt:      row.UpdatedAt.Time,
	}
}

// optStr turns the "" sentinel (common.go's textOf/dateOf/uuidOf
// convention) back into a nil *string for the client-facing DTO, so an
// unset optional field is genuinely absent from the JSON body
// (`omitempty`) rather than serialized as an empty string.
func optStr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// validateTodoCreate validates a todoCreateRequest's shape (id UUID,
// non-empty title within length, due_date format, known priority,
// assignee_id/apiary_id UUID format if present). Field-shape checks run
// first so a malformed id/assignee_id/apiary_id never falls through to the
// (unrelated) ownership checks.
func validateTodoCreate(body todoCreateRequest) (id uuid.UUID, title, description, dueDate, priority, assigneeID, apiaryID string, errs []problem.FieldError) {
	id, err := uuid.Parse(body.ID)
	if err != nil {
		errs = append(errs, problem.FieldError{Field: "id", Code: "invalid", Message: "id must be a UUID"})
	}
	title, titleErrs := validateTitle(body.Title)
	errs = append(errs, titleErrs...)

	description, dueDate, assigneeID, apiaryID, moreErrs := validateOptionalTodoFields(body.Description, body.DueDate, body.AssigneeID, body.ApiaryID)
	errs = append(errs, moreErrs...)

	priority = body.Priority
	if !IsKnownPriority(priority) {
		errs = append(errs, problem.FieldError{Field: "priority", Code: "invalid", Message: fmt.Sprintf("priority must be one of %v", KnownPriorities())})
	}

	return id, title, description, dueDate, priority, assigneeID, apiaryID, errs
}

// validateTodoUpdate validates a todoUpdateRequest the same way
// validateTodoCreate validates a create, minus the id check (the id comes
// from the URL, not the body).
func validateTodoUpdate(body todoUpdateRequest) (title, description, dueDate, priority, assigneeID, apiaryID string, errs []problem.FieldError) {
	title, titleErrs := validateTitle(body.Title)
	errs = append(errs, titleErrs...)

	description, dueDate, assigneeID, apiaryID, moreErrs := validateOptionalTodoFields(body.Description, body.DueDate, body.AssigneeID, body.ApiaryID)
	errs = append(errs, moreErrs...)

	priority = body.Priority
	if !IsKnownPriority(priority) {
		errs = append(errs, problem.FieldError{Field: "priority", Code: "invalid", Message: fmt.Sprintf("priority must be one of %v", KnownPriorities())})
	}

	return title, description, dueDate, priority, assigneeID, apiaryID, errs
}

func validateTitle(raw string) (string, []problem.FieldError) {
	if strings.TrimSpace(raw) == "" {
		return raw, []problem.FieldError{{Field: "title", Code: "required", Message: "title is required"}}
	}
	if len(raw) > maxTitleLength {
		return raw, []problem.FieldError{{Field: "title", Code: "too_long", Message: fmt.Sprintf("title must be at most %d characters", maxTitleLength)}}
	}
	return raw, nil
}

// validateOptionalTodoFields validates the four optional fields shared by
// create and update: description (length), due_date (YYYY-MM-DD format),
// assignee_id (UUID format), apiary_id (UUID format, #51). A nil pointer or
// an explicit empty string both mean "no value" (common.go's
// textOf/dateOf/uuidOf "" sentinel convention) — the caller
// (createTodo/updateTodo) treats an empty assigneeID/apiaryID as "skip the
// ownership check, write NULL".
func validateOptionalTodoFields(description, dueDate, assigneeID, apiaryID *string) (descOut, dueDateOut, assigneeOut, apiaryOut string, errs []problem.FieldError) {
	if description != nil {
		descOut = *description
		if len(descOut) > maxDescriptionLength {
			errs = append(errs, problem.FieldError{Field: "description", Code: "too_long", Message: fmt.Sprintf("description must be at most %d characters", maxDescriptionLength)})
		}
	}
	if dueDate != nil {
		dueDateOut = *dueDate
		if dueDateOut != "" {
			if _, err := time.Parse(dateLayout, dueDateOut); err != nil {
				errs = append(errs, problem.FieldError{Field: "due_date", Code: "invalid", Message: "due_date must be a YYYY-MM-DD date"})
			}
		}
	}
	if assigneeID != nil {
		assigneeOut = *assigneeID
		if assigneeOut != "" {
			if _, err := uuid.Parse(assigneeOut); err != nil {
				errs = append(errs, problem.FieldError{Field: "assignee_id", Code: "invalid", Message: "assignee_id must be a UUID"})
				assigneeOut = "" // malformed: nothing to look up or write
			}
		}
	}
	if apiaryID != nil {
		apiaryOut = *apiaryID
		if apiaryOut != "" {
			if _, err := uuid.Parse(apiaryOut); err != nil {
				errs = append(errs, problem.FieldError{Field: "apiary_id", Code: "invalid", Message: "apiary_id must be a UUID"})
				apiaryOut = "" // malformed: nothing to look up or write
			}
		}
	}
	return descOut, dueDateOut, assigneeOut, apiaryOut, errs
}

// todoRowState is the mutable projection of a todo for history diffing AND
// the sync-apply LWW idempotent-resend/conflict compare (sync.go) — mirrors
// activities' activityRowState shape. Every optional field uses the ""
// sentinel convention (common.go's doc comments): "" means unset,
// indistinguishable from an explicit empty value at this layer by design.
type todoRowState struct {
	title       string
	description string // "" means none
	dueDate     string // "" means none; else YYYY-MM-DD
	priority    string
	status      string
	completedAt string // "" means none; else RFC3339Nano
	assigneeID  string // "" means unassigned; else UUID string
	apiaryID    string // "" means a general, org-level todo (#51); else UUID string
	deletedAt   pgtype.Timestamptz
}

// todoRowStateFromRow projects a stored sqlcgen.TodosTodo row into a
// todoRowState — the "before" half of every REST mutation's history diff.
func todoRowStateFromRow(row sqlcgen.TodosTodo) todoRowState {
	return todoRowState{
		title:       row.Title,
		description: textOf(row.Description),
		dueDate:     dateOf(row.DueDate),
		priority:    row.Priority,
		status:      row.Status,
		completedAt: timestampOf(row.CompletedAt),
		assigneeID:  uuidOf(row.AssigneeID),
		apiaryID:    uuidOf(row.ApiaryID),
		deletedAt:   row.DeletedAt,
	}
}

// fields projects the content columns history.ComputeChange diffs —
// deliberately EXCLUDES deletedAt (mirrors activities' activityRowState.fields):
// writeTodoAuditLogTx/writeTodoAuditLog already special-case
// history.ChangeDelete by nulling the "after" field map entirely, so a
// tombstone's own delta never leaks a raw deleted_at timestamp into the
// audit_log.change payload. Optional fields ("" sentinel) are omitted from
// the map entirely when unset, so a diff between two "unset" states never
// shows up as a spurious ""→"" change.
func (t todoRowState) fields() map[string]any {
	m := map[string]any{
		"title":    t.title,
		"priority": t.priority,
		"status":   t.status,
	}
	if t.description != "" {
		m["description"] = t.description
	}
	if t.dueDate != "" {
		m["due_date"] = t.dueDate
	}
	if t.completedAt != "" {
		m["completed_at"] = t.completedAt
	}
	if t.assigneeID != "" {
		m["assignee_id"] = t.assigneeID
	}
	if t.apiaryID != "" {
		m["apiary_id"] = t.apiaryID
	}
	return m
}

// sameAs reports whether t and o represent the identical row content,
// INCLUDING tombstone state — sync.go's applyTodoOp LWW compare uses this to
// distinguish an idempotent re-send (no domain change, no conflict log
// entry) from a genuine LWW loss.
func (t todoRowState) sameAs(o todoRowState) bool {
	return t.title == o.title && t.description == o.description && t.dueDate == o.dueDate &&
		t.priority == o.priority && t.status == o.status && t.completedAt == o.completedAt &&
		t.assigneeID == o.assigneeID && t.apiaryID == o.apiaryID && t.deletedAt.Valid == o.deletedAt.Valid
}

// writeTodoAuditLogTx appends one history.md §3 row for a REST
// create/update/complete/reopen/delete, in the same local transaction as the
// domain write (FR-HIS-1) — the REST-path counterpart of sync.go's
// writeTodoAuditLog.
func writeTodoAuditLogTx(ctx context.Context, q *sqlcgen.Queries, org pgtype.UUID, userID string, entityID uuid.UUID, changeType string, occurredAt time.Time, before, after todoRowState) error {
	var oldFields map[string]any
	if changeType != history.ChangeCreate {
		oldFields = before.fields()
	}
	newFields := after.fields()
	if changeType == history.ChangeDelete {
		newFields = nil
	}
	changedFields, change, err := history.ComputeChange(changeType, oldFields, newFields)
	if err != nil {
		return fmt.Errorf("compute todo change: %w", err)
	}
	changeJSON, err := json.Marshal(change)
	if err != nil {
		return err
	}
	auditID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	return q.InsertAuditLog(ctx, sqlcgen.InsertAuditLogParams{
		ID:             auditID,
		OrganizationID: org,
		EntityType:     entityTypeTodo,
		EntityID:       pgtype.UUID{Bytes: entityID, Valid: true},
		ChangeType:     changeType,
		ActorUserID:    parseActor(ctx, userID),
		OccurredAt:     pgtype.Timestamptz{Time: occurredAt, Valid: true},
		ChangedFields:  changedFields,
		Change:         changeJSON,
	})
}
