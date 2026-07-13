# client/e2e — walking-skeleton end-to-end test

Playwright test of the M0 slice ([#23](https://github.com/TiagoJVO/beekeepingit/issues/23) §7.3):
**log in → create an apiary → go offline → edit → reconnect → assert it synced
server-side → reload → assert the local state converged → a fresh client
converges via download sync → log out.** It drives the deployed Flutter Web PWA
through the gateway and asserts against the `apiaries` service, so it needs the
**full slice deployed** (see [`infra/README.md`](../../infra/README.md) for the
k3d bring-up).

Runs in CI (`.github/workflows/helm-e2e.yml`, NFR-TST-1, `#162`) against a fresh
k3d cluster the workflow itself brings up — no separate deployed environment
needed. Gated on changes under `infra/**` or `client/e2e/**` (dorny/paths-filter),
same as the rest of that job. The apiary the create step leaves behind is deleted
in `afterAll` (`tests/slice.spec.ts`) via the same REST API the app uses.

The server-side apply semantics (LWW, conflict log, idempotency, tombstones) and
the sync coordinator are additionally covered by fast **Go integration tests**
(`services/apiaries`, `services/sync`) that run in CI without a browser.

## Skipped guards (`test.fixme`) — real bugs found by wiring this e2e

An assertion the e2e correctly caught is marked `test.fixme` (skipped, not
loosened) with the diagnosis inline, so the job stays green while the bug is
tracked. Unskip it when its bug is fixed:

- **RP-initiated logout doesn't return to the app** (#237). After Sign out,
  Authentik shows its own "You've logged out" confirmation interstitial instead
  of redirecting to the app's `post_logout_redirect_uri`, so the browser never
  gets back to `/login`. Fix is on the Authentik/logout-flow side.

## Cold-stack robustness

The e2e runs against a k3d stack the CI job brings up fresh each run, so the spec
hardens its first interactions against a not-yet-warm gateway rather than assuming
instant readiness:

- **`gotoAppRoot`** reloads until the Flutter app actually boots — a freshly-ready
  gateway can answer `502 Bad Gateway` for a short window, and a plain `goto()` then
  lands on a static error page that never becomes the app. The workflow also warms
  the gateway (polls the PWA + OIDC discovery) before starting the browser.
- The login helper waits for the app's Sign in button to be visible before clicking,
  and gives the OIDC callback a generous navigation budget.
- The reconnect-sync step taps the app's **Sync now** override after reconnect: the
  connection-quality gate (#55) doesn't re-probe promptly on connectivity-return
  (it waits out its exponential backoff — up to ~2 min — with no online-event
  interrupt), so a queued write can sit unflushed. That's a real FR-OF-3
  responsiveness gap (see the code comment by the nudge and the PR notes), not just
  CI slowness; the nudge is the intended user action and can be dropped once the
  gate re-probes on reconnect.

## Run

```sh
cd client/e2e
npm install
npm run install-browsers          # chromium
# Point at the deployed stack (defaults target the local k3d gateway; the OIDC
# provider lives on the separate auth.beekeepingit.local host — the test's
# host-resolver rule maps both to loopback):
E2E_BASE_URL=https://app.beekeepingit.local:8443 \
E2E_API_URL=https://app.beekeepingit.local:8443 \
npm test
```

> **Flutter Web note:** the PWA renders to canvas, so the test enables Flutter's
> accessibility semantics (via the a11y placeholder) to get a queryable DOM. If
> semantic selectors prove brittle against a given build, the design's documented
> fallback is a Flutter `integration_test` (§7.3).
