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
