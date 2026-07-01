# Non-Functional Requirements

Each requirement has a **stable ID** (e.g., `NFR-SEC-1`) for traceability. Wording
is refined from `nfrs.txt` but preserves the original intent; open questions link
to `open-questions.md`.

| Prefix | Category |
|---|---|
| NFR-SEC | Security |
| NFR-SCA | Scalability |
| NFR-ARC | Architecture |
| NFR-ROL | Roles, Permissions & Admin App |
| NFR-PER | Performance |
| NFR-MNT | Maintainability |
| NFR-TST | Testability |
| NFR-OBS | Observability |
| NFR-DR | Disaster Recovery |
| NFR-CMP | Compliance |
| NFR-I18N | Internationalization & Localization |
| NFR-AI | AI Constraints |
| NFR-RL | Rate Limiting & Quotas |

---

## Security (NFR-SEC)

- **NFR-SEC-1** — Secure **authentication and authorization**, **data encryption**,
  and protection against common threats including **SQL injection, XSS, and CSRF**.
  - *Resolved (D-7, Q-AUTH):* Keycloak / OIDC; email verification & password reset via Keycloak;
    token lifetimes and **offline login** (cached tokens/JWKS + grace window) designed in
    [`docs/architecture/auth.md`](../docs/architecture/auth.md) / [ADR-0004](../docs/adr/0004-authn-authz.md).

## Scalability (NFR-SCA)

- **NFR-SCA-1** — Designed to handle a **large number of users** and a **large
  amount of data**, with efficient storage/retrieval and the ability to **scale
  horizontally**.
  - *Resolved (D-1):* **full microservices adopted for v1** despite the single-org
    context — accepted trade-off. Realistic near-term scale targets (Q-PERF) still
    needed to size each service.

## Architecture (NFR-ARC)

- **NFR-ARC-1** — **Microservices architecture**: each service owns a specific set
  of features with **clear APIs** for inter-service communication.
- **NFR-ARC-2** — **Abstract infrastructure** behind logical components. The app
  must not be tightly coupled to a specific **database technology** or **cloud
  provider/hosting environment**; abstraction layers must allow switching later.
- **NFR-ARC-3** — Initially run on a **single Kubernetes cluster** with all
  components deployed locally on that cluster. Design for **future cloud-service
  integration** and **independent scaling of components** without forcing it now.
  - *Resolved (D-1):* full microservices is a **v1 requirement**. Service
    decomposition (bounded contexts) becomes a key planning task.

## Roles, Permissions & Admin App (NFR-ROL)

- **NFR-ROL-1** — **Role-based access control**. Every user has a **role**; each
  role has a set of **permissions**. The app enforces access by role + permission.
  Initial roles: **admin** and **user**; more roles may exist later. Provide
  management of roles/permissions: create roles, assign permissions to roles,
  assign roles to users.
  - *Resolved (Q-ROLE):* **admin is organization-scoped** (the membership role; D-3) — manages
    members, roles, org settings and invitations; `user` does field CRUD + AI + history. No
    system-wide app admin in v1. See [`docs/architecture/auth.md`](../docs/architecture/auth.md)
    §5.3 / [ADR-0004](../docs/adr/0004-authn-authz.md).
- **NFR-ROL-2** — A separate **Admin App** (web/browser only, **no offline
  support**) for role management, organization management, and other
  administrative tasks (including rate-limit/quota management — see NFR-RL-1).

## Performance (NFR-PER)

- **NFR-PER-1** — Efficient storage/retrieval, **caching**, and other optimizations
  so the app is **responsive and fast** even at scale.
  - *Open question (Q-PERF):* concrete targets (e.g., screen/API latency, map
    rendering with many markers, offline DB query times).

## Maintainability (NFR-MNT)

- **NFR-MNT-1** — Clear code organization, **modular design**, and adherence to
  coding standards and best practices for easy maintenance and extension.

## Testability (NFR-TST)

- **NFR-TST-1** — Designed for **automated testing**: unit, integration, and
  end-to-end tests to ensure reliability.

## Observability (NFR-OBS)

- **NFR-OBS-1** — **Logging, monitoring, and alerting** so the app can be operated
  in production and issues identified/resolved quickly.

## Disaster Recovery (NFR-DR)

- **NFR-DR-1** — **Backup and restore** mechanisms and the ability to recover from
  failures/disasters quickly and efficiently.
  - *Open question (Q-DR):* RPO/RTO targets and what is backed up (server-side org
    data, and/or on-device data).

## Compliance (NFR-CMP)

- **NFR-CMP-1** — Adherence to relevant regulations/standards. The source lists
  **GDPR and HIPAA** among others.
  - *Note (Q-CMP):* **GDPR applies** (Portugal/EU). **HIPAA is US healthcare** and
    is almost certainly **not applicable** to a beekeeping app — confirm and
    remove if so. Portuguese/EU **beekeeping & food-traceability** regulation is
    the more likely real obligation (see context C-2 / Q-REG).

## Internationalization & Localization (NFR-I18N)

- **NFR-I18N-1** — Support multiple **languages**, **date/time formats**, and other
  locale-specific features. **Focus on English and Portuguese now**, designed to
  add more languages easily later.

## AI Constraints (NFR-AI)

- **NFR-AI-1** — AI features access **only data of the selected context** (scoped).
  **No data is used to train** the AI. Respect user privacy/data security; do not use
  sensitive/personal data without **explicit consent**.
  - *Updated (D-8):* in the PWA phase AI runs **in the cloud**, so context data is
    sent to an external processor → enforce **consent + DPA + no-training + EU
    residency** (Q-AICLOUD). The selected-context scoping still holds.
- **NFR-AI-2** — AI **fully local & offline** (on-device LLM, no external services).
  - *Reordered (D-8/D-10):* now a **native-phase** goal, **not** "for now". The PWA
    phase uses **cloud AI** (online-only); local/offline AI arrives with native.
- **NFR-AI-3** — A **toggle** to run AI **locally or in the cloud**.
  - *Reordered (D-8):* the **cloud path ships first** (PWA phase, near-term default);
    the **local option + toggle** arrive in the native phase. ("Default to local"
    applies once on-device exists.)
  - *Open question (Q-LLM → SP-2, native phase):* on-device model, device specs,
    size, quality bar — spike when approaching native.
- **NFR-AI-4** — **AI write-safety.** AI features **never write domain data directly**.
  An AI-proposed create/update/delete executes **only after explicit user confirmation**
  (human-in-the-loop) and **only via the owning service's authorized, validated, audited
  API** — never by the `ai` service touching domain tables. Proposed actions, like reads,
  **cannot exceed the selected context scope**, and are recorded in **history** (FR-HIS) as
  user-confirmed, AI-assisted changes.
  - *Source (D-11):* replaces the earlier "AI is read-only" stance — the AI can act, but
    only through **confirm + owner-mediated execution**.

## Rate Limiting & Quotas (NFR-RL)

- **NFR-RL-1** — Implement **rate limits and quotas** to prevent abuse and ensure
  fair use, **tiered by subscription level** (higher for premium, lower for free).
  Provide users a view of **current usage and remaining quota**, and **notify**
  them as they approach limits. **Managed via the Admin App** (NFR-ROL-2).
  - *Deferred (D-4):* **rate limiting/quotas are out of v1** (everything free).
    Keep the enforcement mechanism as a design boundary; build limits later.
