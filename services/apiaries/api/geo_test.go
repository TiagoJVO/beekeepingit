package api

// Fast, pure-function unit tests (MEDIUM finding: no fast unit tests for
// pure logic like geoPointInput.validate — only container-backed
// integration tests existed). No DB/Docker dependency.

import (
	"testing"
)

func TestGeoPointInput_Validate(t *testing.T) {
	tests := []struct {
		name      string
		point     *geoPointInput
		wantCodes []string // Code of each expected FieldError, in order
	}{
		{
			name:      "nil point is valid (location is optional)",
			point:     nil,
			wantCodes: nil,
		},
		{
			name:      "valid point",
			point:     &geoPointInput{Type: "Point", Coordinates: []float64{-8.5, 41.2}},
			wantCodes: nil,
		},
		{
			name:      "valid point at boundary",
			point:     &geoPointInput{Type: "Point", Coordinates: []float64{180, 90}},
			wantCodes: nil,
		},
		{
			name:      "valid point at negative boundary",
			point:     &geoPointInput{Type: "Point", Coordinates: []float64{-180, -90}},
			wantCodes: nil,
		},
		{
			name:      "wrong type",
			point:     &geoPointInput{Type: "Polygon", Coordinates: []float64{1, 2}},
			wantCodes: []string{"invalid"},
		},
		{
			name:      "too few coordinates short-circuits bounds checks",
			point:     &geoPointInput{Type: "Point", Coordinates: []float64{1}},
			wantCodes: []string{"invalid"},
		},
		{
			name:      "too many coordinates short-circuits bounds checks",
			point:     &geoPointInput{Type: "Point", Coordinates: []float64{1, 2, 3}},
			wantCodes: []string{"invalid"},
		},
		{
			name:      "longitude out of range",
			point:     &geoPointInput{Type: "Point", Coordinates: []float64{200, 0}},
			wantCodes: []string{"out_of_range"},
		},
		{
			name:      "latitude out of range",
			point:     &geoPointInput{Type: "Point", Coordinates: []float64{0, 200}},
			wantCodes: []string{"out_of_range"},
		},
		{
			name:      "both out of range yields two errors",
			point:     &geoPointInput{Type: "Point", Coordinates: []float64{200, 200}},
			wantCodes: []string{"out_of_range", "out_of_range"},
		},
		{
			name:      "wrong type AND out of range yields both errors",
			point:     &geoPointInput{Type: "Circle", Coordinates: []float64{200, 0}},
			wantCodes: []string{"invalid", "out_of_range"},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			errs := tc.point.validate("location")
			if len(errs) != len(tc.wantCodes) {
				t.Fatalf("validate() returned %d errors %+v, want %d (%v)", len(errs), errs, len(tc.wantCodes), tc.wantCodes)
			}
			for i, wantCode := range tc.wantCodes {
				if errs[i].Code != wantCode {
					t.Fatalf("validate() errs[%d].Code = %q, want %q (full: %+v)", i, errs[i].Code, wantCode, errs)
				}
				if errs[i].Field == "" {
					t.Fatalf("validate() errs[%d].Field is empty, want a dotted path under %q", i, "location")
				}
			}
		})
	}
}

func TestGeoPointInput_LonLat(t *testing.T) {
	t.Run("nil point yields invalid (NULL) params", func(t *testing.T) {
		var p *geoPointInput
		if lon := p.lon(); lon.Valid {
			t.Fatalf("nil.lon() = %+v, want Valid=false", lon)
		}
		if lat := p.lat(); lat.Valid {
			t.Fatalf("nil.lat() = %+v, want Valid=false", lat)
		}
	})

	t.Run("set point yields valid params matching coordinates", func(t *testing.T) {
		p := &geoPointInput{Type: "Point", Coordinates: []float64{-8.5, 41.2}}
		lon := p.lon()
		lat := p.lat()
		if !lon.Valid || lon.Float64 != -8.5 {
			t.Fatalf("lon() = %+v, want {Float64: -8.5, Valid: true}", lon)
		}
		if !lat.Valid || lat.Float64 != 41.2 {
			t.Fatalf("lat() = %+v, want {Float64: 41.2, Valid: true}", lat)
		}
	})
}

func TestParseGeoJSONPoint(t *testing.T) {
	tests := []struct {
		name    string
		raw     string
		wantNil bool
		wantLon float64
		wantLat float64
	}{
		{name: "empty string means unset", raw: "", wantNil: true},
		{name: "malformed JSON yields nil, not a panic", raw: "{not json", wantNil: true},
		{name: "valid point", raw: `{"type":"Point","coordinates":[-8.5,41.2]}`, wantLon: -8.5, wantLat: 41.2},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := parseGeoJSONPoint(tc.raw)
			if tc.wantNil {
				if got != nil {
					t.Fatalf("parseGeoJSONPoint(%q) = %+v, want nil", tc.raw, got)
				}
				return
			}
			if got == nil {
				t.Fatalf("parseGeoJSONPoint(%q) = nil, want a point", tc.raw)
			}
			if got.Coordinates[0] != tc.wantLon || got.Coordinates[1] != tc.wantLat {
				t.Fatalf("parseGeoJSONPoint(%q) = %+v, want lon=%v lat=%v", tc.raw, got, tc.wantLon, tc.wantLat)
			}
		})
	}
}

func TestLonLatFromGeoJSON(t *testing.T) {
	t.Run("unset yields nil-together", func(t *testing.T) {
		lon, lat := lonLatFromGeoJSON("")
		if lon != nil || lat != nil {
			t.Fatalf("lonLatFromGeoJSON(\"\") = (%v, %v), want (nil, nil)", lon, lat)
		}
	})

	t.Run("set point round-trips", func(t *testing.T) {
		lon, lat := lonLatFromGeoJSON(`{"type":"Point","coordinates":[-8.5,41.2]}`)
		if lon == nil || lat == nil {
			t.Fatalf("lonLatFromGeoJSON(...) = (%v, %v), want both set", lon, lat)
		}
		if *lon != -8.5 || *lat != 41.2 {
			t.Fatalf("lonLatFromGeoJSON(...) = (%v, %v), want (-8.5, 41.2)", *lon, *lat)
		}
	})
}

func TestFloat8Ptr(t *testing.T) {
	t.Run("nil yields invalid", func(t *testing.T) {
		got := float8Ptr(nil)
		if got.Valid {
			t.Fatalf("float8Ptr(nil) = %+v, want Valid=false", got)
		}
	})

	t.Run("set value round-trips", func(t *testing.T) {
		v := 12.5
		got := float8Ptr(&v)
		if !got.Valid || got.Float64 != 12.5 {
			t.Fatalf("float8Ptr(&12.5) = %+v, want {Float64: 12.5, Valid: true}", got)
		}
	})
}
