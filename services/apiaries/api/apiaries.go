package api

import (
	"errors"
	"net/http"
	"regexp"
	"strconv"
	"strings"
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

// nearPattern mirrors the contract's `near` schema
// (contracts/openapi/apiaries.openapi.yaml: `pattern: '^-?\d+(\.\d+)?,-?\d+(\.\d+)?$'`)
// — `lon,lat`, each an optionally-signed decimal.
var nearPattern = regexp.MustCompile(`^-?\d+(\.\d+)?,-?\d+(\.\d+)?$`)

// errParseNear is returned by parseNear for any malformed/out-of-range
// `near` value; the handler wraps it in a 422 problem response.
var errParseNear = errors.New(`near must be "lon,lat" with longitude in [-180,180] and latitude in [-90,90]`)

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
// `distance_m` (FR-AP-2, #33) is only set on a `near`-ordered list; other
// reads (get, cursor-paginated list) omit it, matching the contract's
// "only on proximity lists" note on the Apiary schema.
type apiaryDTO struct {
	ID             string       `json:"id"`
	OrganizationID string       `json:"organization_id"`
	Name           string       `json:"name"`
	HiveCount      int32        `json:"hive_count"`
	Location       *geoPointDTO `json:"location,omitempty"`
	DistanceM      *float64     `json:"distance_m,omitempty"`
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

		// `near` (FR-AP-2, #33): when present, list is distance-ordered
		// instead of the default keyset-by-id order. `q` (FR-AP-6) is
		// accepted per the contract but not filtered server-side — D-17
		// resolved search to run client-side over the synced set, so the
		// param is a no-op here rather than unimplemented/rejected.
		if raw := r.URL.Query().Get("near"); raw != "" {
			lon, lat, err := parseNear(raw)
			if err != nil {
				problem.Write(w, r, problem.ValidationFailed("near must be \"lon,lat\"",
					problem.FieldError{Field: "near", Code: "invalid", Message: err.Error()}))
				return
			}
			listApiariesByProximity(w, r, q, org, lon, lat, limit)
			return
		}

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
				CreatedAt:      row.CreatedAt.Time,
				UpdatedAt:      row.UpdatedAt.Time,
			})
		}
		writeJSON(w, http.StatusOK, listDTO{Data: data, Page: page})
	}
}

// listApiariesByProximity serves the `near`-ordered branch of listApiaries:
// offset-paginated (ListApiariesByProximity doc comment explains why it
// can't share ListApiaries' keyset cursor), distance-ascending, each row
// carrying distance_m. cursor is unused for this ordering — the contract's
// `cursor` param is keyset-only — so a `near` request ignores any `cursor`
// it's sent (there is no page concept to resume beyond `limit`/offset-by-page
// here since the offset is always computed from page 1; deep paging a
// proximity list isn't a supported use case per the query's doc comment).
func listApiariesByProximity(w http.ResponseWriter, r *http.Request, q *sqlcgen.Queries, org pgtype.UUID, lon, lat float64, limit int) {
	rows, err := q.ListApiariesByProximity(r.Context(), sqlcgen.ListApiariesByProximityParams{
		OrganizationID: org,
		Lon:            lon,
		Lat:            lat,
		Limit:          int32(limit + 1), //nolint:gosec // limit is clamped to [1,maxLimit=200]
		Offset:         0,
	})
	if err != nil {
		problem.Write(w, r, problem.Internal())
		return
	}

	page := pageDTO{Limit: limit}
	if len(rows) > limit {
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
			DistanceM:      distancePtr(row.DistanceM),
			CreatedAt:      row.CreatedAt.Time,
			UpdatedAt:      row.UpdatedAt.Time,
		})
	}
	writeJSON(w, http.StatusOK, listDTO{Data: data, Page: page})
}

// distancePtr's input is untyped (`interface{}`) in ListApiariesByProximityRow: its SQL
// source (queries/apiaries.sql) is a CTE-computed ST_Distance expression,
// not a real table column, so sqlc can't attach a concrete/nullable pgtype
// to it and falls back to `interface{}` (documented sqlc behavior for
// columns it can't statically resolve). pgx's default type map still scans
// a SQL float8 into that interface{} as a plain float64 (or nil for a NULL
// distance — the "apiary has no location" case, NULLS LAST in the query),
// so distancePtr just narrows that runtime value to *float64 for apiaryDTO.
func distancePtr(v any) *float64 {
	f, ok := v.(float64)
	if !ok {
		return nil
	}
	return &f
}

// parseNear validates and decodes the contract's `near` param
// (`lon,lat`, pattern-checked by nearPattern) into float64s, additionally
// bounds-checking like geoPointInput.validate does for a location body —
// the contract's regex alone would accept an out-of-range value like
// "500,500".
func parseNear(raw string) (lon, lat float64, err error) {
	if !nearPattern.MatchString(raw) {
		return 0, 0, errParseNear
	}
	comma := strings.IndexByte(raw, ',')
	lon, err = strconv.ParseFloat(raw[:comma], 64)
	if err != nil {
		return 0, 0, errParseNear
	}
	lat, err = strconv.ParseFloat(raw[comma+1:], 64)
	if err != nil {
		return 0, 0, errParseNear
	}
	if lon < -180 || lon > 180 || lat < -90 || lat > 90 {
		return 0, 0, errParseNear
	}
	return lon, lat, nil
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
