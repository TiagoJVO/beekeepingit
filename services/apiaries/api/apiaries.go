package api

import (
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/apiaries/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

const (
	defaultLimit = 50
	maxLimit     = 200
)

// geoPointDTO is the client-facing GeoJSON Point shape (GeoPoint schema,
// contracts/openapi/_shared/components.openapi.yaml): `coordinates` are
// `[longitude, latitude]` in WGS84 (EPSG:4326).
type geoPointDTO struct {
	Type        string     `json:"type"`
	Coordinates [2]float64 `json:"coordinates"`
}

// apiaryDTO is the client-facing apiary shape (contracts/openapi/apiaries).
// `location` is populated with the real GeoJSON value when the apiary has
// one set (#31 wires up the PostGIS column deferred by the walking
// skeleton); omitempty leaves it out of the response entirely when unset,
// rather than emitting `"location": null`, which the GeoPoint schema (an
// object, no null variant) doesn't allow for a present-but-null value.
type apiaryDTO struct {
	ID             string       `json:"id"`
	OrganizationID string       `json:"organization_id"`
	Name           string       `json:"name"`
	HiveCount      int32        `json:"hive_count"`
	Location       *geoPointDTO `json:"location,omitempty"`
	Notes          *string      `json:"notes,omitempty"`
	CreatedAt      time.Time    `json:"created_at"`
	UpdatedAt      time.Time    `json:"updated_at"`
}

type pageDTO struct {
	NextCursor *string `json:"next_cursor"`
	Limit      int     `json:"limit"`
}

type listDTO struct {
	Data []apiaryDTO `json:"data"`
	Page pageDTO     `json:"page"`
}

// ReadRouter returns the client-facing read routes (GET /v1/apiaries[/{id}]).
// Mount it behind the OIDC authn + org-resolver middleware so requests are
// org-scoped from the resolved Claims. Combined with the REST write routes
// (POST/PATCH/DELETE, #31) by Router below — kept as its own exported
// constructor since main_test.go's fixture (and any caller wanting read-only
// wiring) mounts it standalone too.
func ReadRouter(pool *pgxpool.Pool) http.Handler {
	q := sqlcgen.New(pool)
	r := chi.NewRouter()
	r.Get("/", listApiaries(q))
	r.Get("/{apiaryId}", getApiary(q))
	return r
}

// Router returns the full client-facing /v1/apiaries surface: the read
// routes above plus the REST write routes (POST/PATCH/DELETE, write.go,
// #31/FR-AP-1). This is what main.go mounts; chi doesn't support Mount-ing
// two separate routers at the identical pattern, so read and write are
// combined into one router here rather than two Mount calls on the same
// path.
func Router(pool *pgxpool.Pool) http.Handler {
	q := sqlcgen.New(pool)
	r := chi.NewRouter()
	r.Get("/", listApiaries(q))
	r.Get("/{apiaryId}", getApiary(q))
	r.Post("/", createApiary(pool))
	r.Patch("/{apiaryId}", updateApiary(pool))
	r.Delete("/{apiaryId}", deleteApiary(pool))
	return r
}

func listApiaries(q *sqlcgen.Queries) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, _, ok := requireOrg(w, r)
		if !ok {
			return
		}

		limit := parseLimit(r.URL.Query().Get("limit"))
		cursor := pgtype.UUID{}
		if raw := r.URL.Query().Get("cursor"); raw != "" {
			c, err := uuid.Parse(raw)
			if err != nil {
				problem.Write(w, r, problem.ValidationFailed("cursor must be a UUID",
					problem.FieldError{Field: "cursor", Code: "invalid", Message: "must be a UUID"}))
				return
			}
			cursor = pgtype.UUID{Bytes: c, Valid: true}
		}

		// Fetch one extra row to know whether a next page exists.
		rows, err := q.ListApiaries(r.Context(), sqlcgen.ListApiariesParams{
			OrganizationID: org,
			Limit:          int32(limit + 1), //nolint:gosec // limit is clamped to [1,maxLimit=200]
			Cursor:         cursor,
		})
		if err != nil {
			problem.Write(w, r, problem.Internal())
			return
		}

		page := pageDTO{Limit: limit}
		if len(rows) > limit {
			next := uuidString(rows[limit-1].ID)
			page.NextCursor = &next
			rows = rows[:limit]
		}

		data := make([]apiaryDTO, 0, len(rows))
		for _, row := range rows {
			data = append(data, apiaryDTO{
				ID:             uuidString(row.ID),
				OrganizationID: uuidString(row.OrganizationID),
				Name:           row.Name,
				HiveCount:      row.HiveCount,
				Location:       parseGeoJSONPoint(row.LocationGeojson),
				Notes:          textPtr(row.Notes),
				CreatedAt:      row.CreatedAt.Time,
				UpdatedAt:      row.UpdatedAt.Time,
			})
		}
		writeJSON(w, http.StatusOK, listDTO{Data: data, Page: page})
	}
}

func getApiary(q *sqlcgen.Queries) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, _, ok := requireOrg(w, r)
		if !ok {
			return
		}
		id, err := uuid.Parse(chi.URLParam(r, "apiaryId"))
		if err != nil {
			problem.Write(w, r, problem.NotFound("apiary not found"))
			return
		}

		row, err := q.GetApiary(r.Context(), sqlcgen.GetApiaryParams{
			OrganizationID: org,
			ID:             pgtype.UUID{Bytes: id, Valid: true},
		})
		if errors.Is(err, pgx.ErrNoRows) {
			problem.Write(w, r, problem.NotFound("apiary not found"))
			return
		}
		if err != nil {
			problem.Write(w, r, problem.Internal())
			return
		}

		w.Header().Set("ETag", etagFor(row.UpdatedAt))
		writeJSON(w, http.StatusOK, apiaryDTO{
			ID:             uuidString(row.ID),
			OrganizationID: uuidString(row.OrganizationID),
			Name:           row.Name,
			HiveCount:      row.HiveCount,
			Location:       parseGeoJSONPoint(row.LocationGeojson),
			Notes:          textPtr(row.Notes),
			CreatedAt:      row.CreatedAt.Time,
			UpdatedAt:      row.UpdatedAt.Time,
		})
	}
}

func parseLimit(raw string) int {
	if raw == "" {
		return defaultLimit
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 1 {
		return defaultLimit
	}
	if n > maxLimit {
		return maxLimit
	}
	return n
}
