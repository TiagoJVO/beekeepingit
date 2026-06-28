# EPIC-13 — Infrastructure, Observability & CI/CD

- **Milestone:** M0 (then ongoing)
- **Phase:** cross-cutting
- **Labels:** type/epic, area/infra, area/observability
- **Requirements:** NFR-ARC-1, NFR-ARC-2, NFR-ARC-3, NFR-OBS-1, NFR-PER-1
- **Depends on:** —
- **Spikes:** none
- **Summary:** Stand up the single-cluster Kubernetes platform (Helm umbrella) with the shared backing services, an infrastructure-abstraction layer, GitOps delivery, the full observability stack, and a path-filtered GitHub Actions CI/CD pipeline for the monorepo. This is the platform foundation every other epic deploys onto.

## Stories

### Task k8s + Helm umbrella chart on a single cluster
- **Labels:** type/task, area/infra, priority/critical
- **Requirements:** NFR-ARC-1, NFR-ARC-3
- **Milestone:** M0
- **Depends on:** —
- **Acceptance criteria:**
  - [ ] A single local Kubernetes cluster is provisioned and documented (e.g. kind/k3d/minikube) with a one-command bring-up.
  - [ ] A Helm **umbrella chart** composes per-service subcharts so the whole platform deploys with one release.
  - [ ] Namespaces, resource requests/limits, and a values schema (per-environment overrides) are defined for each component.
  - [ ] `helm template`/`helm lint` pass in CI and a dry-run renders all manifests without error.
  - [ ] A documented teardown returns the cluster to a clean state with no orphaned resources.
- **Notes:** Single cluster for v1 per NFR-ARC-3 (D-1 keeps microservices but on one cluster). Helm per tech-stack.md. Service subcharts are added incrementally as each service epic lands.

### Task Deploy Postgres+PostGIS, Keycloak, MinIO, gateway/ingress
- **Labels:** type/task, area/infra, priority/critical
- **Requirements:** NFR-ARC-2, NFR-ARC-3
- **Milestone:** M0
- **Depends on:** EPIC-13/k8s + Helm umbrella chart
- **Acceptance criteria:**
  - [ ] PostgreSQL with the **PostGIS** extension is deployed; a smoke query confirms the spatial extension is available.
  - [ ] Postgres is provisioned with a **schema-per-service** convention (D-6) and per-service credentials.
  - [ ] **Keycloak** is deployed with a seeded realm/client usable by services and the client app for login.
  - [ ] **MinIO** (S3-compatible object storage) is deployed and reachable via an S3 client.
  - [ ] A **gateway/ingress** (Traefik or NGINX ingress) routes external traffic to at least one backend service over TLS.
  - [ ] All four components expose health/readiness and come up cleanly on a fresh cluster bring-up.
- **Notes:** Stack per tech-stack.md (Infrastructure) and D-6/D-7. Mirrors the local dev environment in EPIC-00; Keycloak realm detail/RBAC is owned by EPIC-01, TLS hardening by EPIC-14.

### Task Infrastructure abstraction (S3-compatible storage, DB access layer)
- **Labels:** type/task, area/infra, priority/high
- **Requirements:** NFR-ARC-2
- **Milestone:** M0
- **Depends on:** EPIC-13/Deploy Postgres+PostGIS, Keycloak, MinIO, gateway/ingress
- **Acceptance criteria:**
  - [ ] Object storage is accessed through an **S3-compatible abstraction** so MinIO can be swapped for a cloud provider without code changes outside the adapter.
  - [ ] Database access is provided through a logical data-access layer (pgx + sqlc per tech-stack.md), not raw provider-specific calls scattered across services.
  - [ ] Connection details (DB, object storage, broker) are injected via config/secrets, never hardcoded.
  - [ ] A documented example demonstrates switching the storage/DB endpoint via configuration only.
  - [ ] The abstraction boundaries are documented as the seam for future cloud-service integration (NFR-ARC-2/3).
- **Notes:** NFR-ARC-2 mandates not being tightly coupled to a DB technology or cloud/hosting environment. Secrets handling is hardened in EPIC-14.

### Task GitOps (ArgoCD/Flux) deploy to the local cluster
- **Labels:** type/task, area/infra, priority/high
- **Requirements:** NFR-ARC-3, NFR-MNT-1
- **Milestone:** M0
- **Depends on:** EPIC-13/k8s + Helm umbrella chart
- **Acceptance criteria:**
  - [ ] A GitOps controller (ArgoCD or Flux) is installed on the local cluster and reconciles the umbrella chart from the monorepo.
  - [ ] The desired state lives in Git; a manual `kubectl`/`helm` change is reverted by the controller (drift detection works).
  - [ ] A change merged to the tracked branch is automatically synced to the cluster.
  - [ ] Sync status/health for each application is observable in the GitOps tool.
  - [ ] Rollback to a previous Git revision restores the prior deployed state.
- **Notes:** GitOps to a local cluster per the EPIC-13 roadmap entry. CI publishes images and updates manifests (see CI/CD story); the GitOps controller performs the actual deploy.

### Task Observability stack: OTel + Prometheus + Grafana + Loki + Tempo
- **Labels:** type/task, area/observability, area/infra, priority/high
- **Requirements:** NFR-OBS-1, NFR-PER-1
- **Milestone:** M0
- **Depends on:** EPIC-13/k8s + Helm umbrella chart
- **Acceptance criteria:**
  - [ ] An **OpenTelemetry Collector** is deployed and receives traces, metrics, and logs from services.
  - [ ] **Prometheus** scrapes service/infra metrics; **Tempo** stores traces; **Loki** stores logs.
  - [ ] **Grafana** is deployed with data sources wired to Prometheus, Loki, and Tempo and at least one starter dashboard.
  - [ ] Traces, logs, and metrics for a sample request are correlated (trace ID links logs↔traces) end-to-end.
  - [ ] At least one **alerting rule** fires to a configured receiver on a simulated failure condition (e.g. service down / error-rate spike).
  - [ ] The walking-skeleton slice (EPIC-00) shows its traces and logs in this stack, satisfying the M0 observability exit criterion.
- **Notes:** Stack per tech-stack.md (OTel → Prometheus/Loki/Tempo/Grafana). NFR-OBS-1 requires logging, monitoring, and alerting. Concrete performance/latency targets are pending Q-PERF.

### Task CI/CD: GitHub Actions, path-filtered monorepo (build/test/scan/publish/deploy)
- **Labels:** type/task, area/infra, area/security, priority/high
- **Requirements:** NFR-TST-1, NFR-MNT-1, NFR-ARC-3
- **Milestone:** M0
- **Depends on:** EPIC-13/GitOps (ArgoCD/Flux) deploy to the local cluster
- **Acceptance criteria:**
  - [ ] GitHub Actions workflows use **path filters** so only the affected app/service in the monorepo (D-9) builds and tests on a given change.
  - [ ] The pipeline runs lint → unit/integration tests → build for each affected component.
  - [ ] A security/scan stage runs dependency and container-image scanning and fails the build on configured severities (mechanism shared with EPIC-14).
  - [ ] Container images are built and **published** to a registry on merge, tagged by commit.
  - [ ] Deployment is triggered via the GitOps flow (image/manifest update), not manual `kubectl`.
  - [ ] **macOS runners for iOS builds are NOT part of this pipeline at M0** — they are added only at **M5** by EPIC-15; a note/placeholder records this.
- **Notes:** Monorepo CI per D-9 and the EPIC-13 roadmap entry. Scanning detail (tools, policy) is specified in EPIC-14's security-baseline story; this story wires the CI stage. macOS/iOS CI is explicitly deferred to M5 (EPIC-15).
