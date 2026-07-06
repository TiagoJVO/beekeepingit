# Contracts

**Contract-first** API definitions — the source of truth for every client-facing service
boundary. Specs live here **before** the services are scaffolded (D-9: directories appear as
work needs them), so each service epic implements _against a committed contract_ and boundary
(contract) tests can be wired in.

> **Conventions:** the rules these specs follow — REST style, resource naming, pagination,
> the RFC 9457 error format, versioning, and inter-service guidance — are documented in
> [`docs/architecture/api-contracts.md`](../docs/architecture/api-contracts.md) and
> [`docs/adr/0003-api-contract-conventions.md`](../docs/adr/0003-api-contract-conventions.md)
> (issue #108). This README is just the layout + how-to.

## Layout

| Path                                      | What                                                                                                                                                                                                                                                       |
| ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `openapi/_shared/components.openapi.yaml` | The reusable **contract template**: security scheme (Keycloak JWT), pagination params, standard headers, the RFC 9457 `Problem` error schema, and shared responses. Every service spec `$ref`s this — it is _not_ a deployable API on its own (a partial). |
| `openapi/apiaries.openapi.yaml`           | Skeleton for the **apiaries** service (FR-AP) — the walking-skeleton's "create" target (#110).                                                                                                                                                             |
| `openapi/organizations.openapi.yaml`      | Skeleton for the **organizations** service (onboarding + admin surface, FR-ONB / NFR-ROL).                                                                                                                                                                 |
| `openapi/sync.openapi.yaml`               | The **sync** service (#23) — the offline write-back seam: `GET /v1/sync/token` (PowerSync `fetchCredentials`) + `POST /v1/sync/batch` (`uploadData`). See [sync.md](../docs/architecture/sync.md) §3.4/§6.                                                 |

The remaining services from the [service decomposition](../docs/architecture/service-decomposition.md)
(`activities`, `journeys`, `todos`, `ai`, `history`) are stamped from the same template as
their epics start. (`identity`/`organizations` expose only internal resolve endpoints in the
skeleton, so they have no client-facing spec yet beyond the `organizations` skeleton above.)

## Working with the specs

- **OpenAPI 3.1**, one YAML file per service: `openapi/<service>.openapi.yaml`.
- Service specs reference shared pieces with a **relative `$ref`** into `_shared/`. Because a
  spec is split across files, **bundle** it before codegen/publish:

  ```sh
  # lint (recommended ruleset)
  npx @redocly/cli lint contracts/openapi/apiaries.openapi.yaml
  # bundle into a single self-contained document
  npx @redocly/cli bundle contracts/openapi/apiaries.openapi.yaml -o apiaries.bundled.yaml
  ```

  > `security` requirements reference a scheme **by name**, which can't be a cross-file
  > `$ref` — so each service spec declares `bearerAuth` locally as a `$ref` to the shared
  > definition (single source of truth, name resolves locally).

- **Lint + the breaking-change gate run in CI** (`task openapi:lint` in `task ci`;
  `contracts-ci.yml` runs `task openapi:breaking-diff` on PRs touching `contracts/openapi/**`)
  — see [`taskfiles/openapi.yml`](../taskfiles/openapi.yml). Go server-stub/model codegen
  (`task openapi:generate-go`, `oapi-codegen`) is wired too but no-ops until a service adds
  `internal/api/oapi-codegen.yaml`. Dart/TS typed-client codegen is deferred — no client
  consumes a generated client yet and no tool is decided.
- **Contract tests at service boundaries** (#153) run as part of the owning service's own
  integration tests, via `services/servicetemplate/contracttest` — it validates a real HTTP
  response against the service's spec ($ref/allOf-aware). See
  `services/apiaries/main_test.go`'s `TestApiariesSlice_ResponsesConformToOpenAPIContract` for
  the pattern; extend it to other services as each grows a client-facing surface.
