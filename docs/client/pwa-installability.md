# PWA installability — audits & manual verification

**Issue:** #93 · **Requirements:** FR-PL-1 · **Decisions:** [D-10](../../requirements/decisions.md) (PWA-first)

Documents how BeekeepingIT's installability (add-to-home-screen + offline app-shell) is
verified: the automated Lighthouse CI gate, and the manual pass an installability audit alone
can't cover (an audit checks the manifest/service-worker are _present and well-formed_, not
that a real browser actually offers the install prompt and serves the shell offline).

## 1. Automated audit (CI)

`client/lighthouserc.json` runs [Lighthouse CI](https://github.com/GoogleChrome/lighthouse-ci)
(`@lhci/cli`, pinned `0.13.0`) against the built `client/build/web` artifact, as a step in the
`build` job of [`.github/workflows/build-publish.yml`](../../.github/workflows/build-publish.yml)
(`if: matrix.component == 'client'`), right after `flutter build web`. It runs on every PR/push
that touches `client/` (the existing path-filtered matrix), using LHCI's own static file server
against the build output — no live cluster or gateway needed.

**Scope — installability only, not full Lighthouse:** `onlyCategories: ["pwa"]` restricts
collection to the PWA category, and the assertions further narrow to the installability-relevant
audits, each required at `minScore: 1`:

| Audit                  | What it checks                                                               |
| ---------------------- | ---------------------------------------------------------------------------- |
| `installable-manifest` | Manifest + service worker together meet the browser's install requirements   |
| `viewport`             | A `<meta name="viewport">` tag is present (required for install eligibility) |
| `content-width`        | Content isn't wider than the viewport (part of installability, not perf)     |
| `maskable-icon`        | Manifest has a `purpose: maskable` icon (Android adaptive icon)              |
| `themed-omnibox`       | `<meta name="theme-color">` themes the browser address bar                   |
| `splash-screen`        | Manifest has what's needed for a custom splash screen on launch              |

`is-on-https` is skipped at collection time (`skipAudits`) — Lighthouse can't see the real
gateway's TLS termination when auditing a local static build, and HTTPS hosting is already
covered structurally (the `pwa` Helm chart is only ever reached through the TLS-terminating
ingress; see [`docs/architecture/platform.md`](../architecture/platform.md)), not by this audit.

**Deliberately not gated:** Lighthouse's `performance`, `accessibility`, `best-practices`, and
`seo` categories, and the PWA category's non-installability audits (`pwa-cross-browser`,
`pwa-page-transitions`, `pwa-each-page-has-url` — these assume a multi-page app with URL-bar
navigation, not the primary signal for an installable-manifest check). The goal is a gate that
fails on an installability regression (e.g. someone removes the manifest link, drops the
maskable icon, or deletes `theme-color`), not one that's noisy about unrelated perf/SEO drift.

**Run it locally:**

```sh
cd client
flutter pub get && dart run powersync:setup_web
flutter build web --release --no-web-resources-cdn
npx --yes @lhci/cli@0.13.0 autorun --config=./lighthouserc.json
```

Reports land in `client/lhci-report/` (gitignored).

**Known gap the audit does not catch:** Lighthouse's `maskable-icon` audit only checks that the
manifest _declares_ an icon with `purpose: maskable` at the right sizes — it does not check
whether the icon's actual artwork is project-branded. `client/web/icons/*` and `favicon.png`
are still **Flutter's default template logo**, not a BeekeepingIT icon (visually confirmed by
opening `Icon-512.png` — it's the blue Flutter chevron). This is issue #93's "real project app
icons replace Flutter's default template icons" AC, and it remains **unmet**; producing real
brand artwork is a design task, not something this change (an audit + docs pass) can do. Tracked
in #233.

## 2. Served caching policy (as built)

The container that serves the built bundle (`client/nginx.conf`, the `pwa` Helm chart) sends
one explicit header for **everything** it serves (#621):

```text
Cache-Control: no-cache
```

`no-cache` is not "don't store" — it is "store, but revalidate before reuse", so nginx's
`ETag`/`Last-Modified` turn repeat loads into cheap `304 Not Modified` responses while a new
release is picked up on the very next load. Before this, no `Cache-Control` was sent at all and
browsers fell back to **heuristic** caching (an implementation-defined freshness guess derived
from `Last-Modified`), which can hold a stale bundle for an unbounded window after a deploy.

**Nothing is served `immutable`, deliberately.** `flutter build web` emits **no content-hashed
filenames**: `index.html`, `main.dart.js`, `flutter_bootstrap.js`, `flutter.js`, `version.json`,
`manifest.json`, `canvaskit/*`, `sqlite3.wasm`, `powersync_db.worker.js`, and the (per-build
tree-shaken) `assets/fonts/MaterialIcons-Regular.otf` are all **stable names whose bytes change
every release**. A long `max-age=…, immutable` therefore has no safe target here — it would pin
users to a stale build with no reload escape. The same missing hashes are the strongest argument
for keeping the policy **uniform**: mixing `no-cache` on the document with any stale-tolerant
policy on the assets could serve a fresh `index.html` against a previous build's cached
`main.dart.js`, and revalidating everything is what keeps a release atomic.

The header is set at **server** level, not inside the SPA-fallback `location {}`: in nginx an
`add_header` inside a `location` cancels inheritance of **every** server-level `add_header`, which
would silently drop COOP/COEP, `X-Content-Type-Options`, `Referrer-Policy` and the Report-Only
CSP (#89).

This is currently the **only** cache layer: per #619 the deployed `flutter_service_worker.js` is
Flutter's self-unregistering deprecation stub, so no service worker caches the app shell today.
Restoring the offline shell is that issue's work; the header above only makes repeat loads cheap
and releases prompt.

**`no-cache` therefore does not — and cannot — give an offline reload.** It means a stored
response may not be reused without a **successful** revalidation ([RFC 9111
§5.2.2.4](https://www.rfc-editor.org/rfc/rfc9111#section-5.2.2.4)), and with no connectivity that
revalidation fails, so the browser has nothing it is allowed to serve. Under the previous
no-header state, heuristic freshness could sometimes let a repeat visit paint without the
network — accidentally, and just as easily with a stale build. Making the policy explicit is the
right correctness call regardless, but it means #619 (ship a real service worker) is a **hard
prerequisite** for FR-PL-1's offline app-shell AC, not merely the next thing after this; both
issues sit in the same milestone (H1 · Offline shell restored).

Verified live by `client/e2e/tests/cache-headers.spec.ts` through the gateway, from the real
nginx container, in the `helm-e2e` job.

## 3. Manual pass — install + offline-shell-serving

The audits above prove the manifest is well-formed; they do not prove a real browser actually
shows the install prompt, that installing produces a working standalone app, or that anything is
served with the network off. That needs a real browser.

**Partly superseded by §2.** This pass was recorded before it was established that the deployed
`flutter_service_worker.js` is Flutter's self-unregistering deprecation stub. There is therefore
**no service worker caching the app shell today**, so only the _install_ half of this pass is
runnable now; the offline half is blocked on #619 and would deterministically fail if run. The
items below are kept as the historical record, annotated where the record turned out to be wrong.

### What was verified in this pass (static build inspection — no live cluster)

Done as part of this change, against the built `client/build/web` artifact and source
templates, without a live gateway/cluster:

- [x] `manifest.json` is valid JSON with `name`, `short_name`, `start_url`, `display: standalone`,
      `theme_color`, `background_color`, and both a `192x192`/`512x512` icon pair and a
      `maskable` pair, at the declared sizes — confirmed via the Lighthouse
      `installable-manifest`/`maskable-icon` audits against the real asset files (§1). The
      artwork itself is still Flutter's default logo, not project branding — see the "known
      gap" callout in §1.
- [x] `index.html` links the manifest (`<link rel="manifest">`), sets `theme-color` and
      `viewport` meta tags (both were missing before this change — added, see the PR diff),
      and carries the iOS-specific meta tags/`apple-touch-icon` for Safari's non-standard
      install path.
- [ ] ~~Flutter's build (`flutter build web`) generates a service worker
      (`flutter_service_worker.js`) that precaches the app shell (engine/framework JS, fonts,
      the manifest, the icons) — this is Flutter's own web-build behavior, not custom code
      here; confirmed by reading the generated `build/web/flutter_service_worker.js` manifest
      list structure in a local build.~~ **Superseded — this does not hold.** On the pinned
      Flutter (3.44) the generated `flutter_service_worker.js` is Flutter's **self-unregistering
      deprecation stub**: it calls `self.registration.unregister()` on activate, so it precaches
      nothing and removes itself. No service worker caches the app shell today (see §2).
      Unchecked rather than deleted, so the wrong belief this pass acted on stays visible;
      shipping a real service worker is #619.
- [x] The `pwa` Helm chart (`infra/helm/beekeepingit/charts/pwa/`) serves the static bundle
      (`client/Dockerfile` + `nginx.conf`) behind the cluster's TLS-terminating ingress — HTTPS
      is a deployment property of the chart, not something a static-file Lighthouse run can
      itself confirm (§1's `is-on-https` skip).

### What still needs a human device pass

Needs a person with a real Chrome/Android session against a **deployed** (or `flutter run -d
chrome`-served) instance — not reproducible from a static build in this environment:

- [ ] **Chrome desktop/Android install prompt** — open the hosted URL (or
      `flutter run -d chrome` locally), confirm Chrome's install affordance (omnibox icon /
      "Add to Home screen" menu item on Android) appears, and that accepting it installs a
      standalone-windowed app with the BeekeepingIT icon and name.
- [ ] **Offline app-shell serving — blocked on #619, do not run it yet.** The check itself is:
      after installing (or just visiting once), go offline (DevTools → Network → Offline, or
      airplane mode on Android) and reload; the app shell must still load (blank/white screen or
      a browser offline-dino page is a fail). It cannot pass today: nothing caches the shell, and
      `no-cache` forbids reusing a stored response without a successful revalidation (§2). Run it
      once #619 ships a real service worker. Per the issue's scope note, it checks the **shell**
      loads, not that data/API calls work offline — that's PowerSync's local-first sync
      (`EPIC-06`), already covered elsewhere.
- [ ] **Large-device no-offline-requirement check (FR-PL-1)** — on a laptop/desktop viewport,
      confirm the app functions normally online; desktops are not required to pass the offline
      check above, only phones/tablets are.

Record the result of this pass (pass/fail + browser/OS versions used) in the PR or issue
thread when a human runs it; this doc is the procedure, not a substitute for running it.
