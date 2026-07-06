// Package contracttest gives a service's integration tests a way to check that
// its real HTTP responses conform to its own OpenAPI contract
// (contracts/openapi/<service>.openapi.yaml) — catching implementation/spec
// drift the functional assertions in the same tests don't (ADR-0003 §11, #153).
//
// It implements exactly the JSON Schema subset this repo's specs use — $ref
// (local and cross-file), allOf, the object/array/string/number/integer/boolean
// types (including the `type: [X, "null"]` nullable-union form), required,
// const and enum — not general JSON Schema or the full OpenAPI spec.
//
// Relative file $refs (e.g. "./_shared/components.openapi.yaml#/...") are
// resolved against the entrypoint spec's own directory rather than the
// referencing node's — correct for this repo, where the only cross-file
// target (_shared/components.openapi.yaml) never itself refs another file.
package contracttest

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

// Doc is a loaded OpenAPI 3.1 document plus a cache of any other files its
// specs $ref into.
type Doc struct {
	root       map[string]any
	dir        string
	pathPrefix string // spec's servers[0].url (e.g. "/v1"); stripped from request paths
	cache      map[string]map[string]any
}

// Load reads and parses the OpenAPI 3.1 YAML document at specPath.
func Load(specPath string) (*Doc, error) {
	abs, err := filepath.Abs(specPath)
	if err != nil {
		return nil, fmt.Errorf("contracttest: resolve %s: %w", specPath, err)
	}
	root, err := loadYAMLFile(abs)
	if err != nil {
		return nil, err
	}
	d := &Doc{
		root:  root,
		dir:   filepath.Dir(abs),
		cache: map[string]map[string]any{abs: root},
	}
	if servers, ok := root["servers"].([]any); ok && len(servers) > 0 {
		if s, ok := servers[0].(map[string]any); ok {
			if u, ok := s["url"].(string); ok {
				d.pathPrefix = strings.TrimRight(u, "/")
			}
		}
	}
	return d, nil
}

func loadYAMLFile(absPath string) (map[string]any, error) {
	//nolint:gosec // G304: absPath is always a repo-relative OpenAPI spec path built from
	// test-code-supplied input (contracttest.Load's caller, or a spec's own $ref), never
	// external/user input.
	data, err := os.ReadFile(absPath)
	if err != nil {
		return nil, fmt.Errorf("contracttest: read %s: %w", absPath, err)
	}
	var out map[string]any
	if err := yaml.Unmarshal(data, &out); err != nil {
		return nil, fmt.Errorf("contracttest: parse %s: %w", absPath, err)
	}
	return out, nil
}

// ValidateResponseBody asserts that body conforms to the schema this Doc
// declares for method + status at the operation matching concretePath — the
// actual request path used against the running service (e.g.
// "/v1/apiaries/<id>"). The spec's own version prefix (servers[0].url, e.g.
// "/v1") is stripped automatically before matching its version-relative path
// templates. Reports every mismatch found via t.Errorf (does not stop the
// test) so a single response shows its full set of contract violations.
func (d *Doc) ValidateResponseBody(t *testing.T, method, concretePath string, status int, body []byte) {
	t.Helper()
	schema, root, err := d.responseSchema(method, concretePath, status)
	if err != nil {
		t.Fatalf("contracttest: %v", err)
	}
	if schema == nil {
		return // no body declared for this status (e.g. 204) — nothing to check
	}
	var value any
	if err := json.Unmarshal(body, &value); err != nil {
		t.Fatalf("contracttest: response body is not valid JSON: %v\nbody: %s", err, body)
	}
	if errs := d.validate(value, schema, root, "$"); len(errs) > 0 {
		t.Errorf("%s %s -> %d violates its OpenAPI contract:\n  %s", method, concretePath, status, strings.Join(errs, "\n  "))
	}
}

// responseSchema finds the schema (plus the document root any $refs inside it
// should resolve against) declared for method+status on the operation whose
// path template matches concretePath.
func (d *Doc) responseSchema(method, concretePath string, status int) (map[string]any, map[string]any, error) {
	template, err := d.matchPath(concretePath)
	if err != nil {
		return nil, nil, err
	}
	paths, _ := d.root["paths"].(map[string]any)
	pathItem, _ := paths[template].(map[string]any)
	op, ok := pathItem[strings.ToLower(method)].(map[string]any)
	if !ok {
		return nil, nil, fmt.Errorf("no %s operation for path %s (spec template %s)", method, concretePath, template)
	}
	responses, _ := op["responses"].(map[string]any)
	respObj, ok := responses[strconv.Itoa(status)].(map[string]any)
	if !ok {
		respObj, ok = responses["default"].(map[string]any)
		if !ok {
			return nil, nil, fmt.Errorf("no response declared for %s %s -> %d", method, concretePath, status)
		}
	}
	respObj, respRoot := d.resolveSchema(respObj, d.root)
	content, ok := respObj["content"].(map[string]any)
	if !ok {
		return nil, nil, nil // e.g. 204 No Content — nothing to validate
	}
	for _, ct := range []string{"application/json", "application/problem+json"} {
		body, ok := content[ct].(map[string]any)
		if !ok {
			continue
		}
		schema, ok := body["schema"].(map[string]any)
		if !ok {
			return nil, nil, fmt.Errorf("%s %s -> %d: %s has no schema", method, concretePath, status, ct)
		}
		return schema, respRoot, nil
	}
	return nil, nil, fmt.Errorf("%s %s -> %d: no application/json or application/problem+json body declared", method, concretePath, status)
}

// matchPath strips the spec's version prefix from concretePath and finds the
// path template (e.g. "/apiaries/{apiaryId}") it matches.
func (d *Doc) matchPath(concretePath string) (string, error) {
	rel := strings.TrimPrefix(concretePath, d.pathPrefix)
	segs := splitPath(rel)
	paths, _ := d.root["paths"].(map[string]any)
	templates := make([]string, 0, len(paths))
	for k := range paths {
		templates = append(templates, k)
	}
	sort.Strings(templates) // deterministic in case of ambiguity

	for _, tmpl := range templates {
		tsegs := splitPath(tmpl)
		if len(tsegs) != len(segs) {
			continue
		}
		match := true
		for i, ts := range tsegs {
			if strings.HasPrefix(ts, "{") && strings.HasSuffix(ts, "}") {
				continue // path parameter — matches any segment
			}
			if ts != segs[i] {
				match = false
				break
			}
		}
		if match {
			return tmpl, nil
		}
	}
	return "", fmt.Errorf("no path template in the spec matches %s (version-relative %s)", concretePath, rel)
}

func splitPath(p string) []string {
	trimmed := strings.Trim(p, "/")
	if trimmed == "" {
		return nil
	}
	return strings.Split(trimmed, "/")
}

// resolveSchema follows a $ref chain (bounded defensively against cycles) and
// returns the resolved node plus the document root that node's own local
// ("#/...") $refs should resolve against.
func (d *Doc) resolveSchema(schema map[string]any, root map[string]any) (map[string]any, map[string]any) {
	for i := 0; i < 10; i++ {
		refRaw, ok := schema["$ref"]
		if !ok {
			return schema, root
		}
		ref, _ := refRaw.(string)
		resolved, newRoot, err := d.resolveRef(ref, root)
		if err != nil {
			return schema, root // let the missing-data error surface downstream instead
		}
		schema, root = resolved, newRoot
	}
	return schema, root
}

func (d *Doc) resolveRef(ref string, currentRoot map[string]any) (map[string]any, map[string]any, error) {
	filePart, pointerPart, hasHash := strings.Cut(ref, "#")
	if !hasHash {
		return nil, nil, fmt.Errorf("unsupported $ref (no #): %s", ref)
	}
	root := currentRoot
	if filePart != "" {
		abs := filepath.Join(d.dir, filePart)
		cached, ok := d.cache[abs]
		if !ok {
			loaded, err := loadYAMLFile(abs)
			if err != nil {
				return nil, nil, fmt.Errorf("resolve %s: %w", ref, err)
			}
			d.cache[abs] = loaded
			cached = loaded
		}
		root = cached
	}
	var node any = root
	for _, seg := range strings.Split(strings.TrimPrefix(pointerPart, "/"), "/") {
		if seg == "" {
			continue
		}
		m, ok := node.(map[string]any)
		if !ok {
			return nil, nil, fmt.Errorf("cannot resolve %s: %q is not an object", ref, seg)
		}
		node, ok = m[seg]
		if !ok {
			return nil, nil, fmt.Errorf("cannot resolve %s: no key %q", ref, seg)
		}
	}
	m, ok := node.(map[string]any)
	if !ok {
		return nil, nil, fmt.Errorf("resolved %s is not an object", ref)
	}
	return m, root, nil
}

// validate checks value against schema (resolving $ref/allOf first) and
// returns a human-readable message per violation found, prefixed with at (a
// jq-style path into the response body, e.g. "$.data[0].location").
func (d *Doc) validate(value any, schema map[string]any, root map[string]any, at string) []string {
	schema, root = d.resolveSchema(schema, root)

	if allOf, ok := schema["allOf"].([]any); ok {
		return d.validate(value, mergeAllOf(d, allOf, root), root, at)
	}

	var errs []string

	if constVal, ok := schema["const"]; ok {
		if !equalJSON(value, constVal) {
			errs = append(errs, fmt.Sprintf("%s: want const %v, got %v", at, constVal, value))
		}
		return errs
	}

	if enumRaw, ok := schema["enum"].([]any); ok {
		found := false
		for _, e := range enumRaw {
			if equalJSON(value, e) {
				found = true
				break
			}
		}
		if !found {
			errs = append(errs, fmt.Sprintf("%s: %v not in enum %v", at, value, enumRaw))
		}
	}

	if types := schemaTypes(schema["type"]); len(types) > 0 {
		if !typeMatches(value, types) {
			return append(errs, fmt.Sprintf("%s: type mismatch, want %v, got %s", at, types, jsonTypeName(value)))
		}
	}

	switch v := value.(type) {
	case map[string]any:
		if reqRaw, ok := schema["required"].([]any); ok {
			for _, r := range reqRaw {
				key, _ := r.(string)
				if _, present := v[key]; !present {
					errs = append(errs, fmt.Sprintf("%s: missing required property %q", at, key))
				}
			}
		}
		if props, ok := schema["properties"].(map[string]any); ok {
			for key, val := range v {
				propSchema, ok := props[key].(map[string]any)
				if !ok {
					continue // not declared in the spec — additionalProperties is allowed here
				}
				errs = append(errs, d.validate(val, propSchema, root, at+"."+key)...)
			}
		}
	case []any:
		if items, ok := schema["items"].(map[string]any); ok {
			for i, el := range v {
				errs = append(errs, d.validate(el, items, root, fmt.Sprintf("%s[%d]", at, i))...)
			}
		}
	}

	return errs
}

// mergeAllOf flattens an allOf list into one schema: properties and required
// are unioned across branches, everything else from the last branch wins.
// Each branch is resolved against root — correct for this repo's specs, none
// of which put a same-document-only ("#/...") ref inside an allOf branch that
// would need a different root than the allOf's own container.
func mergeAllOf(d *Doc, allOf []any, root map[string]any) map[string]any {
	merged := map[string]any{}
	properties := map[string]any{}
	var required []any
	for _, subRaw := range allOf {
		sub, ok := subRaw.(map[string]any)
		if !ok {
			continue
		}
		sub, _ = d.resolveSchema(sub, root)
		for k, v := range sub {
			switch k {
			case "properties":
				if props, ok := v.(map[string]any); ok {
					for pk, pv := range props {
						properties[pk] = pv
					}
				}
			case "required":
				if req, ok := v.([]any); ok {
					required = append(required, req...)
				}
			default:
				merged[k] = v
			}
		}
	}
	if len(properties) > 0 {
		merged["properties"] = properties
	}
	if len(required) > 0 {
		merged["required"] = required
	}
	return merged
}

func schemaTypes(raw any) []string {
	switch t := raw.(type) {
	case string:
		return []string{t}
	case []any:
		out := make([]string, 0, len(t))
		for _, v := range t {
			if s, ok := v.(string); ok {
				out = append(out, s)
			}
		}
		return out
	default:
		return nil
	}
}

func typeMatches(value any, types []string) bool {
	for _, want := range types {
		switch want {
		case "null":
			if value == nil {
				return true
			}
		case "object":
			if _, ok := value.(map[string]any); ok {
				return true
			}
		case "array":
			if _, ok := value.([]any); ok {
				return true
			}
		case "string":
			if _, ok := value.(string); ok {
				return true
			}
		case "boolean":
			if _, ok := value.(bool); ok {
				return true
			}
		case "integer":
			if f, ok := value.(float64); ok && f == math.Trunc(f) {
				return true
			}
		case "number":
			if _, ok := value.(float64); ok {
				return true
			}
		}
	}
	return false
}

func jsonTypeName(value any) string {
	switch value.(type) {
	case nil:
		return "null"
	case map[string]any:
		return "object"
	case []any:
		return "array"
	case string:
		return "string"
	case bool:
		return "boolean"
	case float64:
		return "number"
	default:
		return fmt.Sprintf("%T", value)
	}
}

// equalJSON compares two decoded JSON/YAML scalars for const/enum matching.
// This repo's specs only use string consts/enums; reflect.DeepEqual covers
// the rest defensively.
func equalJSON(a, b any) bool {
	if as, ok := a.(string); ok {
		bs, ok := b.(string)
		return ok && as == bs
	}
	return reflect.DeepEqual(a, b)
}
