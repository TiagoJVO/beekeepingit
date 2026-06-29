# Rule: Definition of Done

A change is done only when all of the following hold:

- [ ] All acceptance criteria of the story/issue are met.
- [ ] Linked to its requirement IDs (`FR-*/NFR-*`), decisions (`D-*`) and issue/epic
      (`#`, `EPIC-*`) — reference these in the branch, commits, and PR.
- [ ] Honors relevant `D-*` decisions — or a contradiction was confirmed with the user and
      the decision updated; no unresolved `Q-*` was silently assumed.
- [ ] Tests added/updated and **passing in CI** (`NFR-TST`).
- [ ] **Offline & sync** impact considered (client features) — works offline where required.
- [ ] **i18n (EN/PT)** strings externalized; **accessibility** (WCAG 2.2 AA, gloves-friendly) addressed.
- [ ] **Tenancy** enforced (`organization_id` scoping) and **history** recorded for entity changes (`FR-HIS`).
- [ ] **Security**: no secrets committed; input validated; authz checked.
- [ ] Docs updated when behavior/scope changed: `requirements/` (with user confirmation
      for `D-*`/requirement changes), and **`docs/`** to document the architecture as it's
      built (+ an ADR for significant decisions).
- [ ] PR uses `.github/PULL_REQUEST_TEMPLATE.md` and the checklist is complete.
