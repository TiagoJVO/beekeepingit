// Package api holds the sync service's HTTP surface: the client-facing
// sync-token + write-back endpoints and the internal JWKS. The write-back
// coordinator (walking-skeleton.md §4.3, sync.md §6) owns no domain data and
// holds no schema credentials — it only orchestrates calls to owning services'
// internal validate/apply endpoints, forwarding the caller's bearer so each
// re-authenticates and re-scopes (zero-trust).
package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

// activityEntityType is the sync wire entity_type activities' own
// api/sync.go Op carries (client mirror: powersync_schema.dart's
// activityEntityType) — the routing key groupOpsByOwner uses to tell an
// activities op apart from every other (apiary/apiary_counter) op, which
// all default to apiariesURL.
const activityEntityType = "activity"

// Coordinator fans a client transaction out to owning services, grouped by
// each op's entity_type (sync.md §6.1/§6.3: "groups ops by owning
// service"). #39 is the first op kind that isn't owned by apiaries
// (activities) — the two-phase validate-all-then-apply contract already
// anticipated a second service; this is that extension, not a redesign.
// Most pushes are still single-service (sync.md §1's overwhelming-majority
// case) and take the byte-identical single-group fast path (handleSingle);
// only a push that genuinely mixes an apiary/apiary_counter op with an
// activity op (e.g. an apiary created and an activity logged against it in
// the same offline session) exercises the multi-group merge (handleMulti).
type Coordinator struct {
	apiariesURL   string
	activitiesURL string
	client        *http.Client
}

// NewCoordinator builds a Coordinator targeting the apiaries and activities
// services — every op not recognized as an activity op defaults to
// apiariesURL, so this stays additive as further owning services are wired
// in (sync.md §6.3's "adding a second service later changes nothing here"
// promise, now made real for the FIRST actual second service).
func NewCoordinator(apiariesURL, activitiesURL string) (*Coordinator, error) {
	if apiariesURL == "" {
		return nil, fmt.Errorf("sync: NewCoordinator requires apiariesURL")
	}
	if activitiesURL == "" {
		return nil, fmt.Errorf("sync: NewCoordinator requires activitiesURL")
	}
	return &Coordinator{
		// Trim a trailing slash so an operator-supplied URL (env var, config)
		// never produces a double slash when concatenated with the internal
		// endpoint paths below.
		apiariesURL:   strings.TrimRight(apiariesURL, "/"),
		activitiesURL: strings.TrimRight(activitiesURL, "/"),
		client: &http.Client{
			Timeout:   10 * time.Second,
			Transport: otelhttp.NewTransport(http.DefaultTransport),
		},
	}, nil
}

// upstreamResponse is a captured HTTP response from an owning service.
type upstreamResponse struct {
	status      int
	contentType string
	body        []byte
}

// handle groups body's ops by owning service, then runs validate-all then
// apply-all across every INVOLVED service (sync.md §6.1-§6.3), forwarding
// bearer. It returns the response to relay to the client:
//   - validate rejects (422)      → relay that problem+json; nothing applied.
//   - validate/apply unavailable  → 502; the batch stays queued and retries.
//   - apply succeeds              → relay the per-op results (merged, when
//     more than one service was involved).
//
// A body that doesn't parse as a batch of ops at all (grouping finds
// nothing to route) falls back to sending it whole to apiariesURL —
// unchanged from the pre-#39 behavior — so a malformed batch is still
// rejected by an owning service's own JSON decode with its usual "malformed
// sync batch" message, not a bespoke error from this layer.
func (c *Coordinator) handle(ctx context.Context, bearer string, body []byte) upstreamResponse {
	groups, order := groupOpsByOwner(body, c.apiariesURL, c.activitiesURL)
	switch len(groups) {
	case 0:
		return c.handleSingle(ctx, bearer, c.apiariesURL, body)
	case 1:
		return c.handleSingle(ctx, bearer, order[0], groups[order[0]])
	default:
		return c.handleMulti(ctx, bearer, groups, order)
	}
}

// handleSingle is the original (pre-#39) single-owning-service validate-then-
// apply flow, now parameterized by ownerURL/body so it also serves as the
// fast path for a batch that, after grouping, targets exactly one service —
// the overwhelming majority of pushes (sync.md §1).
func (c *Coordinator) handleSingle(ctx context.Context, bearer, ownerURL string, body []byte) upstreamResponse {
	validate, err := c.post(ctx, ownerURL+"/internal/sync/validate", bearer, body)
	if err != nil {
		slog.ErrorContext(ctx, "sync validate call failed", slog.Any("error", err), slog.String("owner", ownerURL))
		return badGateway("sync validation is unavailable")
	}
	switch validate.status {
	case http.StatusOK:
		// proceed to apply
	case http.StatusUnprocessableEntity:
		return validate // relay the field-level rejection; nothing written (§6.2)
	default:
		return badGateway("sync validation failed")
	}

	apply, err := c.post(ctx, ownerURL+"/internal/sync/apply", bearer, body)
	if err != nil {
		slog.ErrorContext(ctx, "sync apply call failed", slog.Any("error", err), slog.String("owner", ownerURL))
		return badGateway("sync apply is unavailable")
	}
	if apply.status != http.StatusOK {
		// A post-validation failure is transient by construction (§6.2); the
		// idempotent batch heals on PowerSync's forward-retry.
		return badGateway("sync apply failed; retry")
	}
	return apply
}

// handleMulti is the multi-owning-service path (sync.md §6.1's "rare,
// offline-only" case — a client transaction that mixes, e.g., an apiary op
// with an activity op): VALIDATE every involved service FIRST — any single
// rejection aborts the whole push before anything is applied anywhere,
// preserving the "no partial wrong apply" guarantee (§6.3) across services —
// then APPLY every involved service and merge their per-op results into one
// response. order is iterated (not the map directly) purely so validation
// failures/log lines are deterministic across runs; it has no effect on
// correctness (every group is still validated/applied regardless of order).
func (c *Coordinator) handleMulti(ctx context.Context, bearer string, groups map[string][]byte, order []string) upstreamResponse {
	for _, ownerURL := range order {
		validate, err := c.post(ctx, ownerURL+"/internal/sync/validate", bearer, groups[ownerURL])
		if err != nil {
			slog.ErrorContext(ctx, "sync validate call failed", slog.Any("error", err), slog.String("owner", ownerURL))
			return badGateway("sync validation is unavailable")
		}
		switch validate.status {
		case http.StatusOK:
		case http.StatusUnprocessableEntity:
			return validate
		default:
			return badGateway("sync validation failed")
		}
	}

	var merged []json.RawMessage
	for _, ownerURL := range order {
		apply, err := c.post(ctx, ownerURL+"/internal/sync/apply", bearer, groups[ownerURL])
		if err != nil {
			slog.ErrorContext(ctx, "sync apply call failed", slog.Any("error", err), slog.String("owner", ownerURL))
			return badGateway("sync apply is unavailable")
		}
		if apply.status != http.StatusOK {
			return badGateway("sync apply failed; retry")
		}
		var parsed struct {
			Results []json.RawMessage `json:"results"`
		}
		if err := json.Unmarshal(apply.body, &parsed); err != nil {
			slog.ErrorContext(ctx, "sync apply response unparsable", slog.Any("error", err), slog.String("owner", ownerURL))
			return badGateway("sync apply response was malformed")
		}
		merged = append(merged, parsed.Results...)
	}

	out, err := json.Marshal(struct {
		Results []json.RawMessage `json:"results"`
	}{Results: merged})
	if err != nil {
		slog.Error("marshal merged apply response", slog.Any("error", err))
		return badGateway("sync apply response could not be assembled")
	}
	return upstreamResponse{status: http.StatusOK, contentType: "application/json", body: out}
}

// rawBatchOp is the minimal shape groupOpsByOwner needs to read from each
// op — just enough to route it, never re-interpreting the op's own domain
// data (that stays the owning service's job).
type rawBatchOp struct {
	EntityType string `json:"entity_type"`
}

// groupOpsByOwner splits body's `{"ops":[...]}` array by each op's
// entity_type into one sub-batch per owning service (activityEntityType →
// activitiesURL; everything else, including a malformed/unrecognized op →
// apiariesURL, its long-standing default owner). A body that isn't a valid
// `{"ops":[...]}` object, or whose ops array is empty, returns (nil, nil) —
// the caller (handle) falls back to the whole-body passthrough. order lists
// each group's URL exactly once, in first-seen order, so callers can walk
// the map deterministically.
func groupOpsByOwner(body []byte, apiariesURL, activitiesURL string) (map[string][]byte, []string) {
	var rb struct {
		Ops []json.RawMessage `json:"ops"`
	}
	if err := json.Unmarshal(body, &rb); err != nil || len(rb.Ops) == 0 {
		return nil, nil
	}

	grouped := map[string][]json.RawMessage{}
	var order []string
	for _, raw := range rb.Ops {
		var meta rawBatchOp
		_ = json.Unmarshal(raw, &meta) // malformed op ⇒ falls through to apiariesURL; that service's own validate rejects it with field-level detail
		ownerURL := apiariesURL
		if meta.EntityType == activityEntityType {
			ownerURL = activitiesURL
		}
		if _, ok := grouped[ownerURL]; !ok {
			order = append(order, ownerURL)
		}
		grouped[ownerURL] = append(grouped[ownerURL], raw)
	}

	out := make(map[string][]byte, len(grouped))
	for _, ownerURL := range order {
		b, err := json.Marshal(struct {
			Ops []json.RawMessage `json:"ops"`
		}{Ops: grouped[ownerURL]})
		if err != nil {
			// Practically unreachable (every element is already-valid JSON
			// captured via json.RawMessage), but fail safe: fall back to the
			// whole-body passthrough rather than silently dropping a group.
			return nil, nil
		}
		out[ownerURL] = b
	}
	return out, order
}

func (c *Coordinator) post(ctx context.Context, url, bearer string, body []byte) (upstreamResponse, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return upstreamResponse{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	if bearer != "" {
		req.Header.Set("Authorization", bearer)
	}

	resp, err := c.client.Do(req)
	if err != nil {
		return upstreamResponse{}, err
	}
	defer resp.Body.Close()

	// Cap the upstream response read symmetrically with the request-side cap
	// (maxBatchBytes) — an owning service is trusted, but not to the point of
	// letting a runaway or misbehaving response exhaust memory here.
	out, err := io.ReadAll(io.LimitReader(resp.Body, maxBatchBytes))
	if err != nil {
		return upstreamResponse{}, err
	}
	return upstreamResponse{status: resp.StatusCode, contentType: resp.Header.Get("Content-Type"), body: out}, nil
}

func badGateway(detail string) upstreamResponse {
	// RFC 9457 problem, built through the shared Problem shape (the shared
	// problem package has no 502 constructor, so it's assembled here rather
	// than hand-rolled as a JSON string). code lets clients branch on
	// "retryable upstream".
	p := problem.Problem{
		Title:  "Bad Gateway",
		Status: http.StatusBadGateway,
		Detail: detail,
		Code:   "sync.upstream_unavailable",
	}
	body, err := json.Marshal(p)
	if err != nil {
		// Marshaling a static struct of plain strings/ints cannot fail in
		// practice; fall back to a minimal, still-valid problem+json body
		// rather than panicking or losing the 502 semantics.
		slog.Error("marshal bad gateway problem", slog.Any("error", err))
		body = []byte(`{"title":"Bad Gateway","status":502,"code":"sync.upstream_unavailable"}`)
	}
	return upstreamResponse{status: http.StatusBadGateway, contentType: "application/problem+json", body: body}
}
