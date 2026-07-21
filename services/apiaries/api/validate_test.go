package api

// Fast, pure-function unit tests (MEDIUM finding: the apiaries service only
// had container-backed integration tests — no fast unit tests for pure
// logic). These run with no DB/Docker dependency at all (`go test ./api/...`
// completes in milliseconds), covering parseNear (apiaries.go) and mergeOp
// (sync.go) with table-driven cases. geoPointInput.validate has its own
// table-driven tests in geo_test.go.

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

// hasFieldError reports whether errs contains a FieldError for the given
// dotted field path with the given code — the shared assertion the
// location-required tests below use.
func hasFieldError(errs []problem.FieldError, field, code string) bool {
	for _, e := range errs {
		if e.Field == field && e.Code == code {
			return true
		}
	}
	return false
}

func TestParseNear(t *testing.T) {
	tests := []struct {
		name    string
		raw     string
		wantLon float64
		wantLat float64
		wantErr bool
	}{
		{name: "valid positive", raw: "10.5,20.25", wantLon: 10.5, wantLat: 20.25},
		{name: "valid negative both", raw: "-8.5,41.2", wantLon: -8.5, wantLat: 41.2},
		{name: "valid integers", raw: "0,0", wantLon: 0, wantLat: 0},
		{name: "boundary max", raw: "180,90", wantLon: 180, wantLat: 90},
		{name: "boundary min", raw: "-180,-90", wantLon: -180, wantLat: -90},
		{name: "lon out of range positive", raw: "180.1,0", wantErr: true},
		{name: "lon out of range negative", raw: "-180.1,0", wantErr: true},
		{name: "lat out of range positive", raw: "0,90.1", wantErr: true},
		{name: "lat out of range negative", raw: "0,-90.1", wantErr: true},
		{name: "wildly out of range", raw: "500,500", wantErr: true},
		{name: "missing comma", raw: "10.5 20.25", wantErr: true},
		{name: "empty", raw: "", wantErr: true},
		{name: "extra comma", raw: "10.5,20.25,30", wantErr: true},
		{name: "non-numeric lon", raw: "abc,20.25", wantErr: true},
		{name: "non-numeric lat", raw: "10.5,abc", wantErr: true},
		{name: "trailing comma only", raw: "10.5,", wantErr: true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			lon, lat, err := parseNear(tc.raw)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("parseNear(%q) = (%v, %v, nil), want an error", tc.raw, lon, lat)
				}
				return
			}
			if err != nil {
				t.Fatalf("parseNear(%q) unexpected error: %v", tc.raw, err)
			}
			if lon != tc.wantLon || lat != tc.wantLat {
				t.Fatalf("parseNear(%q) = (%v, %v), want (%v, %v)", tc.raw, lon, lat, tc.wantLon, tc.wantLat)
			}
		})
	}
}

func TestParseLimit(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want int
	}{
		{name: "empty uses default", raw: "", want: defaultLimit},
		{name: "valid within range", raw: "10", want: 10},
		{name: "zero falls back to default", raw: "0", want: defaultLimit},
		{name: "negative falls back to default", raw: "-5", want: defaultLimit},
		{name: "non-numeric falls back to default", raw: "abc", want: defaultLimit},
		{name: "exactly max", raw: "200", want: maxLimit},
		{name: "above max clamps to max", raw: "9999", want: maxLimit},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := parseLimit(tc.raw); got != tc.want {
				t.Fatalf("parseLimit(%q) = %d, want %d", tc.raw, got, tc.want)
			}
		})
	}
}

// mergeOpTS is an arbitrary fixed timestamp used only as mergeOp's op.UpdatedAt
// stand-in for the delete branch below — mergeOp doesn't otherwise inspect it.
var mergeOpTS = time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)

func strPtr(s string) *string   { return &s }
func i32Ptr(v int32) *int32     { return &v }
func f64Ptr(v float64) *float64 { return &v }

func TestMergeOp_Put(t *testing.T) {
	tests := []struct {
		name    string
		current rowState
		data    apiaryData
		want    rowState
	}{
		{
			name:    "put with all fields set replaces everything",
			current: rowState{name: "Old", hive: 3, notes: "old notes", placeLabel: "Old Place", lon: f64Ptr(1), lat: f64Ptr(2)},
			data: apiaryData{
				Name: strPtr("New"), HiveCount: i32Ptr(7), Notes: strPtr("new notes"),
				PlaceLabel: strPtr("New Place"), LocationLon: f64Ptr(3), LocationLat: f64Ptr(4),
			},
			want: rowState{name: "New", hive: 7, notes: "new notes", placeLabel: "New Place", lon: f64Ptr(3), lat: f64Ptr(4)},
		},
		{
			name:    "put with absent hive_count preserves current.hive (#256)",
			current: rowState{name: "Old", hive: 12},
			data:    apiaryData{Name: strPtr("New")},
			want:    rowState{name: "New", hive: 12},
		},
		{
			name:    "put with absent optional fields resets them to unset (full replace)",
			current: rowState{name: "Old", hive: 5, notes: "notes", placeLabel: "Place", lon: f64Ptr(1), lat: f64Ptr(2)},
			data:    apiaryData{Name: strPtr("New"), HiveCount: i32Ptr(5)},
			want:    rowState{name: "New", hive: 5},
		},
		{
			name:    "put on create (empty current) with absent hive_count defaults to 0",
			current: rowState{},
			data:    apiaryData{Name: strPtr("Fresh")},
			want:    rowState{name: "Fresh", hive: 0},
		},
		{
			name:    "put with only lon set (no lat) leaves location unset",
			current: rowState{name: "X"},
			data:    apiaryData{Name: strPtr("X"), LocationLon: f64Ptr(5)},
			want:    rowState{name: "X"},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			op := Op{Op: "put", UpdatedAt: mergeOpTS}
			got := mergeOp(tc.current, op, tc.data)
			if !got.sameAs(tc.want) {
				t.Fatalf("mergeOp(put) = %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestMergeOp_Patch(t *testing.T) {
	tests := []struct {
		name    string
		current rowState
		data    apiaryData
		want    rowState
	}{
		{
			name:    "patch overlays only provided fields",
			current: rowState{name: "Old", hive: 3, notes: "old notes", placeLabel: "Old Place"},
			data:    apiaryData{HiveCount: i32Ptr(9)},
			want:    rowState{name: "Old", hive: 9, notes: "old notes", placeLabel: "Old Place"},
		},
		{
			name:    "patch with no fields is a no-op over current",
			current: rowState{name: "Same", hive: 1, notes: "n"},
			data:    apiaryData{},
			want:    rowState{name: "Same", hive: 1, notes: "n"},
		},
		{
			name:    "patch sets location only when both lon and lat present",
			current: rowState{name: "X"},
			data:    apiaryData{LocationLon: f64Ptr(1)},
			want:    rowState{name: "X"},
		},
		{
			name:    "patch sets location when both present",
			current: rowState{name: "X"},
			data:    apiaryData{LocationLon: f64Ptr(1), LocationLat: f64Ptr(2)},
			want:    rowState{name: "X", lon: f64Ptr(1), lat: f64Ptr(2)},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			op := Op{Op: "patch", UpdatedAt: mergeOpTS}
			got := mergeOp(tc.current, op, tc.data)
			if !got.sameAs(tc.want) {
				t.Fatalf("mergeOp(patch) = %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestMergeOp_Delete(t *testing.T) {
	current := rowState{name: "Live", hive: 4, notes: "n"}
	ts := mergeOpTS.Add(time.Hour)
	op := Op{Op: "delete", UpdatedAt: ts}

	got := mergeOp(current, op, apiaryData{})

	if got.name != current.name || got.hive != current.hive || got.notes != current.notes {
		t.Fatalf("mergeOp(delete) changed non-tombstone fields: got %+v, want scalar fields unchanged from %+v", got, current)
	}
	if !got.deletedAt.Valid {
		t.Fatalf("mergeOp(delete) deletedAt.Valid = false, want true")
	}
	if !got.deletedAt.Time.Equal(ts) {
		t.Fatalf("mergeOp(delete) deletedAt.Time = %v, want %v (op.UpdatedAt)", got.deletedAt.Time, ts)
	}
}

// validPoint is a well-formed in-bounds GeoJSON point used by the
// location-required tests below (mainland Portugal, matching the dev-seed
// region).
func validPoint() *geoPointInput {
	return &geoPointInput{Type: "Point", Coordinates: []float64{-8.6, 41.1}}
}

// TestValidateCreate_LocationRequired is #341's REST-path unit guard: location
// is now mandatory on create (FR-AP-7), so a body without one is rejected with
// a field-level `location`/`required` error, while a body carrying a valid
// point is not.
func TestValidateCreate_LocationRequired(t *testing.T) {
	t.Run("missing location is rejected", func(t *testing.T) {
		_, errs := validateCreate(apiaryCreateRequest{ID: uuid.NewString(), Name: "Encosta Nova"})
		if !hasFieldError(errs, "location", "required") {
			t.Fatalf("validateCreate(no location) errs = %+v, want a location/required error", errs)
		}
	})
	t.Run("valid location passes the location check", func(t *testing.T) {
		_, errs := validateCreate(apiaryCreateRequest{ID: uuid.NewString(), Name: "Encosta Nova", Location: validPoint()})
		if hasFieldError(errs, "location", "required") {
			t.Fatalf("validateCreate(with location) errs = %+v, want no location/required error", errs)
		}
	})
}

// TestValidateApiaryOp_PutLocationRequired is #341's sync-apply (offline
// create) unit guard: a full `put` must carry both coordinates, so a put
// without location is rejected, a put with a partial/whole location passes the
// location-required check, and a `patch` (which never clears location) is
// exempt.
func TestValidateApiaryOp_PutLocationRequired(t *testing.T) {
	mustData := func(m map[string]any) json.RawMessage {
		b, err := json.Marshal(m)
		if err != nil {
			t.Fatalf("marshal op data: %v", err)
		}
		return b
	}
	ts := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)

	t.Run("put without location is rejected", func(t *testing.T) {
		op := Op{Op: "put", EntityType: "apiary", ID: uuid.NewString(), UpdatedAt: ts,
			Data: mustData(map[string]any{"name": "Encosta Nova"})}
		if errs := validateApiaryOp(0, op); !hasFieldError(errs, "ops[0].data.location", "required") {
			t.Fatalf("validateApiaryOp(put, no location) errs = %+v, want a location/required error", errs)
		}
	})
	t.Run("put with location passes the location check", func(t *testing.T) {
		op := Op{Op: "put", EntityType: "apiary", ID: uuid.NewString(), UpdatedAt: ts,
			Data: mustData(map[string]any{"name": "Encosta Nova", "location_lon": -8.6, "location_lat": 41.1})}
		if errs := validateApiaryOp(0, op); hasFieldError(errs, "ops[0].data.location", "required") {
			t.Fatalf("validateApiaryOp(put, with location) errs = %+v, want no location/required error", errs)
		}
	})
	t.Run("patch without location is exempt", func(t *testing.T) {
		op := Op{Op: "patch", EntityType: "apiary", ID: uuid.NewString(), UpdatedAt: ts,
			Data: mustData(map[string]any{"name": "Renamed"})}
		if errs := validateApiaryOp(0, op); hasFieldError(errs, "ops[0].data.location", "required") {
			t.Fatalf("validateApiaryOp(patch, no location) errs = %+v, want no location/required error", errs)
		}
	})
}
