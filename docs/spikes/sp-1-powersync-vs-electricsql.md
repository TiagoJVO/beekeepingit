# SP-1 — PowerSync vs ElectricSQL (offline sync engine)

- **Spike:** SP-1 (#54) · **Epic:** #103 (EPIC-DESIGN) · **Milestone:** M0 · **Date:** 2026-07-01
- **Resolves:** [D-6](../../requirements/decisions.md) engine pick → **PowerSync** ([ADR-0005](../adr/0005-sync-engine-choice.md))
- **Informs:** [Q-SYNC](../../requirements/open-questions.md) conflict policy · **Requirements:** FR-OF-1, FR-OF-2, NFR-ARC-2
- **Outcome:** **PowerSync (self-hosted Open Edition).** A working throwaway prototype demonstrated
  create → offline edit → sync + server-authoritative LWW/conflict-log on a local k8s cluster (**8/8 checks**).

> Research spike — **no production code committed**. This report is the durable record: the
> comparison, what the prototype proved, and how to reproduce it.

## 1. Question

D-6 chose "PowerSync **or** ElectricSQL, final pick via SP-1." Pick one, judged on: Flutter **web**
SDK maturity + **PWA offline persistence** (wa-sqlite over IndexedDB/OPFS, incl. **iOS** durability),
conflict handling, **self-hosting on k8s**, and operational cost — for an **offline-first** (FR-OF-1/2),
**Flutter** (D-5), **PWA-first** (D-10) app whose writes go through the owning service (D-11/D-12).

## 2. Head-to-head (current as of mid-2026)

| Dimension              | **PowerSync**                                                                                                                 | **ElectricSQL** (electric-next)                                                         |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Sync model             | Bidirectional: server→client (Sync Rules/buckets → client **SQLite**); client→server via **upload queue** + backend connector | **Read-path only**: Postgres → clients as **Shapes** over HTTP                          |
| Offline                | **First-class**: offline reads **+ writes**, persistent crash-surviving queue                                                 | Offline **reads only**; write queue + persistence + conflict = **DIY** ("out of scope") |
| Web/PWA local store    | `sqlite3.wasm` + workers; **OPFS** preferred, **IndexedDB** fallback                                                          | Bring-your-own (e.g. PGlite)                                                            |
| Flutter client (D-5)   | **Official** SDK incl. **web** (OPFS)                                                                                         | **No official** Flutter/Dart client (TS + Elixir only)                                  |
| Write path (D-11/D-12) | Through your **backend API** (connector)                                                                                      | Through your **own API**                                                                |
| Conflict handling      | Server-authoritative, in your backend (LWW/merge/reject) → **matches Q-SYNC**                                                 | N/A in engine (no writes)                                                               |
| Self-host on k8s       | ✅ **Open Edition** (`journeyapps/powersync-service`, FSL-1.1→Apache-2.0)                                                     | ✅ Apache-2.0 Elixir service                                                            |
| Cost                   | Self-host free; Cloud ~$49+/mo                                                                                                | Self-host free; Cloud usage-based                                                       |

**Web/PWA persistence detail (PowerSync):** v2.0 (2026) defaults to **OPFS** on Chrome/Firefox; v2.2.0
(2026-05-27) makes **OPFS work in Safari without COOP/COEP** cross-origin-isolation headers (simplifies
PWA hosting). OPFS preferred (fast), **IndexedDB** fallback (compatible). **iOS caveat:** Safari evicts
OPFS/IndexedDB for unused PWAs (~7-day heuristic) — a _browser_ constraint, not engine-specific; iOS is
last in D-10. Mitigate with persistent-storage requests / a native wrapper later.

**Verdict:** For an **offline-first Flutter** app, PowerSync is the only fit. ElectricSQL (electric-next)
is a read-path engine that puts the entire offline write/queue/conflict stack — and a Flutter client —
on us.

## 3. Prototype (what actually ran)

Stood up locally, **self-hosted on k8s** (kind), to validate the offline path on real components:

```text
Playwright (headless Chromium)
  └─ @powersync/web PWA (Vite; OPFS/IndexedDB local SQLite)
        │  fetchCredentials → GET /api/auth/token   (JWT, RS256/JWKS)
        │  uploadData       → POST /api/data         (offline CRUD batch)
        ▼
   backend (Node) ── writes with server-authoritative LWW + conflict log ──▶  Postgres (wal_level=logical)
        ▲                                                                         │  logical replication
        └───────────────  PowerSync service (Open Edition)  ◀─────────────────────┘  (publication "powersync")
                          Sync Rules: apiaries + organizations  ── streams ──▶ client SQLite
```

Domain slice: a seeded org + two apiaries (`Serra Norte` 12, `Ribeira Sul` 8), mirroring D-2 (hive
count on apiary) and org-scoped per FR-TEN. Everything ran in namespace `sp1` on a single-node kind
cluster inside WSL2.

### What it proved — 8/8 automated checks

1. **Initial sync ↓** — client SQLite hydrated from Postgres via logical replication.
2. **Offline create** — new apiary `Encosta Nova` persisted locally (OPFS) with the network cut.
3. **Offline edit** — `Serra Norte` 12 → 20 persisted locally; **server unchanged** (still 12) while offline.
4. **Concurrent server change** — another "device" set `Serra Norte` → 99 with a newer timestamp.
5. **Reconnect: create synced ↑** — `Encosta Nova` appeared in Postgres (via the connector).
6. **Server-authoritative LWW** — the older offline edit (20) **lost** to the newer server value (99).
7. **Client converged** — local `Serra Norte` corrected to 99 after sync.
8. **Conflict logged** — `sync_conflict_log` row with winning (server 99) and losing (client 20) payloads.

This confirms the **Q-SYNC default**: _server-authoritative, record-level last-write-wins + conflict log_.

## 4. How to reproduce (key config)

**Postgres** — logical replication + publication (both required by PowerSync):

```yaml
args: ["-c", "wal_level=logical", "-c", "max_wal_senders=10", "-c", "max_replication_slots=10"]
```

```sql
CREATE PUBLICATION powersync FOR ALL TABLES;   -- in the source DB only
-- PowerSync bucket storage uses a SEPARATE database (so the publication never captures it)
```

**PowerSync service** (`journeyapps/powersync-service:latest`, k8s `args: ["start","-r","unified"]`),
config mounted at `/config/service.yaml`:

```yaml
replication:
  connections: [{ type: postgresql, uri: !env PS_DATA_SOURCE_URI, sslmode: disable }]
storage: { type: postgresql, uri: !env PS_STORAGE_SOURCE_URI, sslmode: disable }
port: !env PS_PORT
sync_config: { path: sync-config.yaml }
client_auth:
  jwks_uri: !env PS_JWKS_URL
  allow_local_jwks: true # required for an internal http:// JWKS URL
  audience: ["powersync-dev", "powersync"]
```

```yaml
# sync-config.yaml — edition-3 streams = the replicated client slice
config: { edition: 3 }
streams:
  global:
    { auto_subscribe: true, queries: ["SELECT * FROM apiaries", "SELECT * FROM organizations"] }
```

> Production scopes the slice **per-org** via a parameterized stream keyed on the JWT (the client-slice
> design is #106's). k8s gotcha: use `args:` (not `command:`) so the image's entrypoint runs.

**Backend write path** — the owning-service connector, server-authoritative LWW + conflict log
(one DB transaction per push = D-12 atomic write-back at single-service scope):

```js
// POST /api/data  { batch: [ { op:'PUT'|'PATCH'|'DELETE', table, id, data } ] }
const inc = data,
  incAt = new Date(inc.updated_at);
const srv = (await q("SELECT * FROM apiaries WHERE id=$1", [id])).rows[0];
if (!srv)
  insert(id, inc); // create
else if (incAt >= new Date(srv.updated_at))
  update(id, inc); // LWW: client newer → apply
else logConflict(srv, inc); // server newer → keep server, log
```

**Client** — `@powersync/web` with the standard connector (`fetchCredentials` → token; `uploadData`
→ `getNextCrudTransaction()` → POST batch → `complete()`). Vite needs `vite-plugin-wasm` +
`vite-plugin-top-level-await` and `optimizeDeps.exclude: ['@journeyapps/wa-sqlite','@powersync/web']`.

The throwaway manifests/scripts (kind bootstrap, Postgres, PowerSync, backend, the PWA, and the
Playwright driver) lived in the session scratchpad and were torn down; the essentials above are
sufficient to rebuild it.

## 5. Handoff to #106 (still open)

- **Cross-service write-back atomicity** (D-12): the PowerSync queue is one `uploadData` batch, but our
  write-back **fans out to multiple owning services** (no cross-schema transaction) → saga/coordinator
  design is #106's; the engine does not solve it.
- **Org-scoped Sync Rules** (the real client slice), the **sync-publication contract** each service
  honors, tombstones/deletes, client↔server validation parity, and the **"synced" status + notify-and-fix
  UX** (FR-OF-2).
- **iOS PWA storage durability** — validate when iOS is in scope (D-10).

## 6. Sources

- PowerSync Flutter web support — <https://docs.powersync.com/client-sdk-references/flutter/flutter-web-support>
- PowerSync self-hosting — <https://docs.powersync.com/intro/self-hosting> · FSL — <https://powersync.com/legal/fsl>
- powersync-service image — <https://hub.docker.com/r/journeyapps/powersync-service>
- ElectricSQL client development — <https://electric.ax/docs/guides/client-development>
- Independent comparison — <https://queryplane.com/blog/electricsql-vs-powersync-vs-replicache/>
