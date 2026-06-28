# EPIC-08 — AI Assistant (cloud)

- **Milestone:** M3
- **Phase:** PWA
- **Labels:** type/epic, area/ai
- **Requirements:** FR-AI-1, NFR-AI-1, NFR-CMP-1, NFR-SEC-1, NFR-TST-1
- **Depends on:** EPIC-02, EPIC-03, EPIC-04, EPIC-05, EPIC-14
- **Spikes:** none (SP-2 on-device LLM is native-phase, EPIC-15 — out of scope here)
- **Summary:** A cloud-first natural-language assistant that answers questions about the organization's beekeeping data by translating them into structured, read-only queries. A server-side Go AI gateway calls a hosted LLM (e.g. the Claude API), runs scoped queries against Postgres, and returns answers; online-only, with explicit consent and GDPR safeguards before any data leaves the device.

## Stories

### [Feature] AI gateway Go service calling a hosted LLM (e.g. Claude API)
- **Labels:** type/feature, area/ai, area/security, priority/high
- **Requirements:** FR-AI-1, NFR-AI-1, NFR-SEC-1
- **Milestone:** M3
- **Depends on:** EPIC-00 (shared Go service template), EPIC-14 (security baseline, secrets)
- **Acceptance criteria:**
  - [ ] A Go AI gateway service exposes an endpoint that accepts a natural-language question plus a context scope and returns a natural-language answer (FR-AI-1)
  - [ ] The service orchestrates the NL→query flow server-side by calling a hosted LLM (e.g. the Claude API); the LLM is never called from the client (D-8)
  - [ ] LLM API keys and provider credentials stay server-side, are loaded from the secrets mechanism (EPIC-14), and never appear in client code or logs (NFR-SEC-1)
  - [ ] The endpoint validates the Keycloak JWT and rejects unauthenticated or expired requests with the standard error format
  - [ ] Requests are online-only: when the client is offline the AI feature is disabled/unavailable with a clear message (D-8, NFR-AI-2 deferred)
  - [ ] LLM call failures, timeouts, and rate-limit responses are handled gracefully and surfaced as a user-friendly error without leaking provider internals
- **Notes:** Cloud-first per D-8 (PWA phase uses a hosted model; on-device LLM + local/cloud toggle deferred to the native phase, EPIC-15). Stack and server-side orchestration per tech-stack.md (AI assistant section). Provider choice (e.g. Claude API) is gated by Q-AICLOUD.

### [Feature] NL→structured-query (tool-calling) over org data
- **Labels:** type/feature, area/ai, area/security, priority/high
- **Requirements:** FR-AI-1, NFR-AI-1, NFR-SEC-1
- **Milestone:** M3
- **Depends on:** EPIC-08 (AI gateway), EPIC-02 (Apiaries), EPIC-03 (Activities), EPIC-04 (Journeys), EPIC-05 (Todos)
- **Acceptance criteria:**
  - [ ] The LLM translates a question into a structured query / tool call (not free-text SQL) over the organization's apiaries, activities, journeys, and todos (FR-AI-1, D-8)
  - [ ] The set of callable tools/queries is a fixed, parameterized all-list; the model selects a tool and supplies parameters but cannot author arbitrary queries
  - [ ] All generated queries are read-only and parameterized, with no INSERT/UPDATE/DELETE/DDL reachable through the AI path (NFR-SEC-1)
  - [ ] Numeric answers (totals, sums, counts) are computed by the structured query against Postgres, not hallucinated by the model (accuracy for totals/overdue todos per D-8)
  - [ ] A question the tool set cannot answer returns a graceful "I can't answer that from your data" response rather than a fabricated answer
  - [ ] Tool definitions and the NL→query mapping have automated tests covering tool selection, parameter binding, and the read-only guarantee (NFR-TST-1)
- **Notes:** Structured-query / tool-calling approach per D-8 and tech-stack.md. This story is read-only by construction; the broader guardrail enforcement is covered by the Guardrails story.

### [Feature] Chat UI + context scope selector (org/apiary/journey)
- **Labels:** type/feature, area/ai, area/i18n-a11y, priority/high
- **Requirements:** FR-AI-1, NFR-AI-1
- **Milestone:** M3
- **Depends on:** EPIC-08 (AI gateway), EPIC-11 (i18n & a11y baseline)
- **Acceptance criteria:**
  - [ ] The Flutter PWA provides a chat UI where a user can ask questions and see answers in a conversation thread (FR-AI-1)
  - [ ] A context-scope selector lets the user choose organization (default), a specific apiary, or a specific journey, and the selected scope is sent with each question (FR-AI-1)
  - [ ] The chat clearly indicates the active scope so the user knows which data the answer is drawn from
  - [ ] The chat is disabled with an explanatory message when offline (online-only per D-8) and when AI consent has not been granted (Q-AICLOUD)
  - [ ] The chat UI meets the i18n (EN+PT) and accessibility (WCAG 2.2 AA, keyboard + screen reader) baselines from EPIC-11
  - [ ] Loading, error, and empty states are handled so the user always gets feedback while a question is processing
- **Notes:** Scope selection (org default / apiary / journey) per FR-AI-1. a11y/i18n owned by EPIC-11; this story consumes that baseline. Consent gating provided by the Consent + GDPR story.

### [Feature] Consent + GDPR (DPA, no-training, EU residency, PII minimization)
- **Labels:** type/feature, area/ai, area/security, priority/high
- **Requirements:** NFR-AI-1, NFR-CMP-1, FR-HIS-1
- **Milestone:** M3
- **Depends on:** EPIC-14 (GDPR consent records, privacy policy)
- **Acceptance criteria:**
  - [ ] The cloud AI feature requires explicit, opt-in user consent before any organization data is sent to the external LLM processor (NFR-AI-1, Q-AICLOUD)
  - [ ] Consent is recorded with actor + timestamp and can be withdrawn; withdrawing consent immediately disables the cloud AI feature, and the consent change is recorded in history (FR-HIS-1)
  - [ ] The integration relies on a provider DPA with a documented no-training guarantee, and EU data residency is configured/verified for the chosen provider (Q-AICLOUD, NFR-CMP-1)
  - [ ] PII minimization is enforced: only the data needed to answer the scoped question is sent, with user-attribution/identifiers minimized or omitted from prompts where not required (Q-AICLOUD)
  - [ ] The consent UX explains, in EN and PT, what data may leave the device, where it is processed, and that it is not used for training
  - [ ] The consent flow and the withdraw→disable behavior have automated tests (NFR-TST-1)
- **Notes:** Gated by Q-AICLOUD (provider choice, DPA, no-training, EU residency, explicit-consent UX, PII minimization). Ties into the GDPR work in EPIC-14 (consent records, privacy policy). Cloud processing rationale per D-8.

### [Task] Guardrails: read-only, scoped, parameterized
- **Labels:** type/task, area/ai, area/security, priority/high
- **Requirements:** FR-AI-1, NFR-AI-1, NFR-SEC-1
- **Milestone:** M3
- **Depends on:** EPIC-08 (NL→structured-query), EPIC-01 (org-scoped authorization)
- **Acceptance criteria:**
  - [ ] Every AI-issued query is constrained to the requesting user's organization, and the selected context scope (apiary/journey) further narrows it; data outside the scope is never returned (NFR-AI-1, FR-AI-1)
  - [ ] All queries reaching the database from the AI path are read-only and parameterized; a test proves no write/DDL path is reachable (NFR-SEC-1)
  - [ ] Prompt-injection attempts in the user's question cannot widen the scope, change the org filter, or cause non-allow-listed actions
  - [ ] AI requests are subject to the same org-scoped authorization middleware as the rest of the platform (EPIC-01), enforced server-side regardless of client input
  - [ ] Inputs and outputs are size-bounded and validated so a malformed or oversized question is rejected cleanly (NFR-SEC-1)
  - [ ] Guardrail behavior (scope confinement, read-only, injection resistance) is covered by automated tests (NFR-TST-1)
- **Notes:** Guardrails are server-side and independent of the client. Scope enforcement layers on the org-scoped authZ from EPIC-01 (FR-TEN). Read-only/parameterized design per D-8 and tech-stack.md.

### [Task] Example-question coverage tests (FR-AI examples)
- **Labels:** type/task, area/ai, priority/medium
- **Requirements:** FR-AI-1, NFR-TST-1
- **Milestone:** M3
- **Depends on:** EPIC-08 (NL→structured-query), EPIC-05 (Todos with area association)
- **Acceptance criteria:**
  - [ ] An automated test suite verifies the assistant correctly answers "What are the activities performed at apiary X in the last month?" against seeded data (FR-AI-1)
  - [ ] The suite verifies "What is the total amount of honey harvested in the last year?" returns the correct computed total (FR-AI-1)
  - [ ] The suite verifies "What are the todos due in the next week?" returns the correct due-soon todos (FR-AI-1)
  - [ ] The suite verifies "What are the todos that are overdue?" returns the correct overdue todos (FR-AI-1)
  - [ ] The suite verifies "What are the todos that are pending for the area of apiary X?" returns the correct area-scoped todos (FR-AI-1)
  - [ ] Each example is asserted against a known fixture dataset so results are deterministic and regressions are caught (NFR-TST-1)
- **Notes:** Covers the example questions enumerated in FR-AI-1. The "area of apiary X" example requires the todo↔apiary/area association from EPIC-05 (Q-TODO). These are coverage tests for the structured-query layer, not new product features (no scope beyond FR-AI-1).
