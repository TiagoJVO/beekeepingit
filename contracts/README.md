# Contracts

**Contract-first** API definitions — the source of truth for every client-facing service
boundary. Specs live here **before** the services are scaffolded (D-9: directories appear as
work needs them), so each service epic implements *against a committed contract* and boundary
(contract) tests can be wired in.

> **Conventions:** the rules these specs follow — REST style, resource naming, pagination,
> the RFC 9457 error format, versioning, and inter-service guidance — are documented in
> [`docs/architecture/api-contracts.md`](../docs/architecture/api-contracts.md) and
> [`docs/adr/0003-api-contract-conventions.md`](../docs/adr/0003-api-contract-conventions.md)
> (issue #108). This README is just the layout + how-to.

## Layout

| Path | What |
|---|---|
| `openapi/_shared/components.openapi.yaml` | The reusable **contract template**: security scheme (Keycloak JWT), pagination params, standard headers, the RFC 9457 `Problem` error schema, and shared responses. Every service spec `$ref`s this — it is *not* a deployable API on its own (a partial). |
| `openapi/apiaries.openapi.yaml` | Skeleton for the **apiaries** service (FR-AP) — the walking-skeleton's "create" target (#110). |
| `openapi/organizations.openapi.yaml` | Skeleton for the **organizations** service (onboarding + admin surface, FR-ONB / NFR-ROL). |

The remaining services from the [service decomposition](../docs/architecture/service-decomposition.md)
(`identity`, `activities`, `journeys`, `todos`, `ai`, `history`) are stamped from the same
template as their epics start.

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

- **Contract tests + `spectral`/`redocly` lint in CI** are wired with the platform in
  **EPIC-13** (see [`FOLLOWUPS.md`](../FOLLOWUPS.md)); until then, lint locally with the
  command above.
