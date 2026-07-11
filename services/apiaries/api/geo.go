// Package api (this file) — GeoJSON <-> PostGIS `geography(Point,4326)`
// conversion helpers for the REST write handlers (#31) and ETag/If-Match
// optimistic-concurrency helpers, shared by apiaries.go (reads) and write.go
// (POST/PATCH/DELETE).
package api

import (
	"encoding/json"
	"fmt"
	"strconv"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

// geoPointInput is the wire shape accepted on write (ApiaryCreate/ApiaryUpdate's
// `location`, contracts/openapi/_shared/components.openapi.yaml's GeoPoint):
// GeoJSON Point, `coordinates` = [longitude, latitude] (WGS84/EPSG:4326).
type geoPointInput struct {
	Type        string    `json:"type"`
	Coordinates []float64 `json:"coordinates"`
}

// validate checks p against the GeoPoint schema (type == "Point", exactly 2
// coordinates) plus reasonable lon/lat bounds — mirrors the "location
// validation (valid GeoJSON Point if present — reasonable lat/lon bounds)"
// requirement. field is the dotted JSON path used in the resulting
// problem.FieldError (e.g. "location").
func (p *geoPointInput) validate(field string) []problem.FieldError {
	if p == nil {
		return nil
	}
	var errs []problem.FieldError
	if p.Type != "Point" {
		errs = append(errs, problem.FieldError{Field: field + ".type", Code: "invalid", Message: "type must be \"Point\""})
	}
	if len(p.Coordinates) != 2 {
		errs = append(errs, problem.FieldError{Field: field + ".coordinates", Code: "invalid", Message: "coordinates must have exactly 2 elements [longitude, latitude]"})
		return errs // out-of-bounds checks below need exactly 2 elements
	}
	lon, lat := p.Coordinates[0], p.Coordinates[1]
	if lon < -180 || lon > 180 {
		errs = append(errs, problem.FieldError{Field: field + ".coordinates[0]", Code: "out_of_range", Message: "longitude must be between -180 and 180"})
	}
	if lat < -90 || lat > 90 {
		errs = append(errs, problem.FieldError{Field: field + ".coordinates[1]", Code: "out_of_range", Message: "latitude must be between -90 and 90"})
	}
	return errs
}

// lon/lat return the point's coordinates as sqlc's nullable float8 params for
// the InsertApiaryWithLocation/UpdateApiaryWithLocation queries — Valid:false
// (both) clears/omits the location, matching a nil *geoPointInput.
func (p *geoPointInput) lon() pgtype.Float8 {
	if p == nil {
		return pgtype.Float8{}
	}
	return pgtype.Float8{Float64: p.Coordinates[0], Valid: true}
}

func (p *geoPointInput) lat() pgtype.Float8 {
	if p == nil {
		return pgtype.Float8{}
	}
	return pgtype.Float8{Float64: p.Coordinates[1], Valid: true}
}

// parseGeoJSONPoint converts a GetApiary/ListApiaries/... row's
// `location_geojson` column (COALESCE(ST_AsGeoJSON(location), ”)::text — a
// PostGIS-produced `{"type":"Point","coordinates":[lon,lat]}` string, or ""
// when the row has no location) into the client-facing geoPointDTO, or nil
// when unset.
func parseGeoJSONPoint(raw string) *geoPointDTO {
	if raw == "" {
		return nil
	}
	var pt geoPointDTO
	if err := json.Unmarshal([]byte(raw), &pt); err != nil {
		// ST_AsGeoJSON always produces well-formed GeoJSON for a Point
		// geography; a decode failure here is a server-side invariant
		// violation, not a client input problem — surfaced as nil (omitted
		// from the response) rather than panicking the request.
		return nil
	}
	return &pt
}

// etagFor derives a deterministic, opaque ETag from a row's updated_at —
// already the row's LWW version stamp (sync.go/data-model.md §4.3), so it
// changes exactly when the row's mutable content changes and is stable
// across reads that observe the same version. Quoted per RFC 9110 §8.8.3
// (ETag values are quoted strings).
func etagFor(updatedAt pgtype.Timestamptz) string {
	return fmt.Sprintf("%q", strconv.FormatInt(updatedAt.Time.UnixNano(), 36))
}
