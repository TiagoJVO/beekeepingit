---
name: markdownlint-and-toolchain
description: >-
  How BeekeepingIT's markdownlint gate works and how to verify it locally. Use when writing or
  editing any Markdown file with fenced code blocks (ASCII diagrams, directory trees, route/table
  listings) — every opening fence needs a language tag (`.markdownlint-cli2.yaml` enforces MD040
  by default; this repo's convention is ` ```text ` for non-code content). Also use whenever a
  markdownlint/Node-based tool fails locally with an ESM `SyntaxError: Invalid regular expression
  flags` — that means the toolchain `mise.toml` pins (Node 22) isn't actually active in your
  shell, not that the target files are broken.
---

# Markdownlint gate & mise toolchain verification

## Fenced code blocks need a language tag (MD040)

`prettier --write` passing is **not** evidence markdownlint will pass — they check different
things, and prettier doesn't touch fence languages. `task ci` runs both; a bare ` ``` ` opening
fence (ASCII diagrams, directory trees, route/table listings, log samples — any non-source-code
content) fails `MD040/fenced-code-language`.

- Default to ` ```text ` for non-code content — the convention already used in
  `docs/architecture/sync.md`, `docs/architecture/history.md`, `docs/spikes/sp-1-*.md`, and root
  `README.md`'s repo-layout tree. Grep for it before guessing if unsure:
  `grep -rn '^```text$' docs/`.
- The closing fence stays bare (` ``` ` with no language) — only the _opening_ fence needs the tag.
- When fixing a CI-reported batch of these errors, the number of openers you tag should exactly
  match the reported error count — verify by counting bare vs. tagged fences before re-pushing.

## `mise` may not be active in a non-interactive/tool-spawned shell

`mise.toml` pins `node = "22"` for this repo. If you invoke `npx markdownlint-cli2` (or any
Node-based repo tool) from a shell where `mise` isn't on `PATH` — which happens in some
non-interactive/tool-spawned shells — it silently falls back to whatever system Node is
installed, which may be much older.

**Symptom:** an ESM loader error like:

```text
SyntaxError: Invalid regular expression flags
    at ESMLoader.moduleStrategy (node:internal/modules/esm/translators:...)
```

(often surfaced from a transitive dependency such as `string-width`, which uses a regex `v` flag
Node 20+ requires). This is a **toolchain-activation problem, not a real lint failure** — don't
debug the target Markdown/code, and don't conclude "this can't be verified locally."

**Fix, in order of preference:**

1. Run the repo's own task, not a bare `npx` — `task lint` (or `task ci`) goes through the
   `mise`-managed toolchain already, so it uses the pinned Node.
2. Check whether `mise` is actually active before assuming the environment is unfixable:
   `which mise` and `mise current node`. If `mise` isn't found, that's the root cause.
3. If you must invoke a tool directly and can't activate `mise` in the current shell, that's a
   real local-verification gap — say so explicitly (don't silently skip), and let CI (which does
   run through the pinned toolchain) be the source of truth for that check.
