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
- [ ] If this change creates a **new top-level directory** (e.g. `infra/`, `client/`,
      `services/`) for the first time, add its row to **`CLAUDE.md`'s repo map** (and update
      its lifecycle note) and update **`README.md`'s** "Status" line / repository-layout tree —
      in the same PR, not a follow-up. Both are entry-point maps, not documentation — point to
      the real docs (`docs/`, or the new directory's own `README.md`), don't restate them.
- [ ] PR uses `.github/PULL_REQUEST_TEMPLATE.md` and the checklist is complete.
