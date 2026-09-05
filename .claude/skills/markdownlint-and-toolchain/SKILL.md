---
name: markdownlint-and-toolchain
description: >-
  The two things about BeekeepingIT's Markdown gate that aren't obvious. Use when writing or
  editing Markdown with fenced code blocks (ASCII diagrams, directory trees, route/table listings)
  — every opening fence needs a language tag, and this repo's convention is a `text` tag for
  non-code content. Also use whenever markdownlint or any Node-based repo tool fails with an ESM
  `SyntaxError: Invalid regular expression flags` — that means the mise.toml toolchain pins
  (Node 22) aren't active in your shell, not that the target files are broken.
---

# Markdown fences & mise toolchain gotchas

## Non-code fences are ` ```text `

`.markdownlint-cli2.yaml` enforces MD040, so every **opening** fence needs a language tag. For
non-source-code content — ASCII diagrams, directory trees, route/table listings, log samples — this
repo's convention is ` ```text ` (see `docs/architecture/sync.md`, `docs/architecture/history.md`,
root `README.md`). The **closing** fence stays bare.

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
