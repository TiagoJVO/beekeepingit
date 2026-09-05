## Summary

<!-- What does this PR change and why? -->

## Related issues

<!-- Closes #123, Relates to #456. Cite the requirement IDs (FR-*/NFR-*) and decisions (D-*) this implements. -->

Closes #

## Type of change

- [ ] Feature
- [ ] Bug fix
- [ ] Refactor / chore
- [ ] Docs
- [ ] Infra / CI

## How was this tested?

<!-- Unit / integration / e2e / manual. Include commands or steps. -->

## Definition of Done

<!-- This is THE checklist (.claude/rules/definition-of-done.md points here). Tick truthfully; strike through what does not apply and say why. -->

- [ ] All acceptance criteria of the linked issue are met
- [ ] Requirement IDs (`FR-*`/`NFR-*`), decisions (`D-*`) and the issue are referenced above; no `D-*` contradicted and no open `Q-*` silently assumed
- [ ] Tests added/updated and passing in CI
- [ ] Offline & sync impact considered (client changes work offline where required)
- [ ] i18n (EN/PT) strings externalized; accessibility (WCAG 2.2 AA, gloves-friendly) addressed
- [ ] Tenancy enforced (`organization_id` scoping) and history recorded for entity changes (`FR-HIS`)
- [ ] Security: no secrets committed; input validated; authz checked
- [ ] Docs updated if behavior or scope changed (`requirements/` with user confirmation for `D-*` changes, `docs/` + ADR for significant decisions, CODEMAPS if routes/tables/dependencies changed)
- [ ] New top-level directory (if any) has its `CLAUDE.md` row and `README.md` tree line

## Before merge

<!-- Anything this PR still owes. Delete the section if it owes nothing. Every item here is either done before merge, or becomes a GitHub Issue opened from this PR and linked here — never a note kept for later. -->

- [ ] …
