# App icon generator

**Issue:** [#682](https://github.com/TiagoJVO/beekeepingit/issues/682) (this tool) ·
[#233](https://github.com/TiagoJVO/beekeepingit/issues/233) /
[#681](https://github.com/TiagoJVO/beekeepingit/issues/681) (the shipped set) ·
**Requirements:** FR-PL-1 · **Decisions:**
[D-10](../../../requirements/decisions.md) (PWA-first)

Regenerates the branded PWA icon set from the committed vector master, so a future size
change (a new maskable size, an iOS splash set, a store listing asset) is a re-run rather
than a redraw. Before this, the PNGs in `client/web/` were the only artefact — the master
and the script that rasterised them lived outside the repo.

## Run it

```sh
cd client/tool/icons
npm ci
npm run generate     # rewrite client/web/icons/*.png + client/web/favicon.png
npm run check        # regenerate in memory; fail if the committed PNGs differ
```

Or from the repo root, without changing directory:

```sh
task web:icons         # generate
task web:icons-check   # verify
```

## What it produces

| File                              | Size | Bee fills | Why                                                               |
| --------------------------------- | ---- | --------- | ----------------------------------------------------------------- |
| `web/icons/Icon-192.png`          | 192² | 86%       | `purpose: any` — drawn as-is, so it can fill the tile             |
| `web/icons/Icon-512.png`          | 512² | 86%       | as above; also the splash-screen source                           |
| `web/icons/Icon-maskable-192.png` | 192² | 62%       | `purpose: maskable` — must survive Android's circle/squircle crop |
| `web/icons/Icon-maskable-512.png` | 512² | 62%       | as above                                                          |
| `web/favicon.png`                 | 32²  | 92%       | browser tab — tiny, so it needs every pixel it can get            |

All five are a **white bee on the brand amber `#F9A825`**, which is also the manifest's
`theme_color` and `background_color` — so the icon, the splash screen and the browser
omnibox agree rather than the icon being the odd one out.

## The master

`melargil-logo-master.pdf` is the **Melargil brand master**: the wordmark with the amber
bee above it, as a pure-vector PDF (no embedded raster), MediaBox `[-1 -1 220.7698 99.3446]` — i.e. 221.77 × 100.34 pt,
transparent background. Supplied by the project owner from the brand asset set
(`Melargil Preto_FundoFundoRansparente.pdf`) and committed here with their approval, so the
PNGs in `client/web/` have a recorded lineage.

> It is **brand artwork**, not a generic asset: it carries the Melargil identity and is not
> covered by this repository's licence for reuse elsewhere. Treat a change to it as a brand
> change, not a code change.

## How the bee is extracted

The master is the whole logo — wordmark included — but the app icon is the bee alone. The
generator isolates it geometrically rather than by hand-editing the vector:

1. **Rasterise page 1 at `scale: 24`** → 5323 × 2409 px on a transparent canvas. Far above
   any output size, so the downscale to 512/192/32 is a clean area-average.
2. **Bound the amber.** The bee is the only amber artwork on the page (the wordmark is
   near-black), so the pixels matching `a > 128 && r > 200 && 110 < g < 220 && b < 110`
   give the bee’s raw bounding box: **845 × 723 at (2193, 391)**. The script logs the **padded** box (879 × 757 at (2176, 374)), which is what step 3 produces.
3. **Pad 2%** of the longest side, for breathing room inside the tile.
4. **Drop dark pixels from the crop.** The pad reaches down into the wordmark. The wordmark
   is near-black; the bee anti-aliases amber-to-transparent and never goes dark — so
   zeroing the alpha of anything with all three channels under 140 removes the glyphs
   without eroding the bee's edge.
5. **Recolour to flat white**, alpha preserved, and centre on an amber tile.

## Pinned, and byte-reproducible

The committed PNGs are the **byte-for-byte** output of this script at these constants with
these exact dependency versions — `npm run check` asserts it, and that assertion is the
point of the tool. Both dependencies are pinned to an exact version (no `^`) with a
committed lockfile:

- **`pdfjs-dist` 3.11.174** (legacy CJS build) — renders the vector paths.
- **`@napi-rs/canvas` 1.0.8** — the Skia canvas pdf.js draws onto, and the PNG encoder.

> **The trap that costs an afternoon.** pdf.js draws through the browser canvas APIs, so
> Node needs `DOMMatrix`, `Path2D` and `ImageData` installed as globals from
> `@napi-rs/canvas` **before pdf.js is loaded**. Without them pdf.js only _warns_ and then
> silently mis-renders the paths — you get a plausible-looking but wrong raster, not an
> error. That is why the script loads pdf.js through a runtime `createRequire` instead of a
> static `import` (ESM imports are hoisted and would run first).

Because the output must stay byte-stable, treat every constant in the script as
load-bearing: change one and the icon set changes, so `npm run generate` and the resulting
PNGs belong in the same commit.

**Known limit:** byte-identity has been verified on Windows x64 with the versions above. The
lockfile pins every platform's `@napi-rs/canvas` binary, but Skia rasterisation has not been
confirmed byte-identical across operating systems — which is why `npm run check` is _not_
wired into the repo-wide `task lint` / `task ci` fan-out (see
[#687](https://github.com/TiagoJVO/beekeepingit/issues/687)). It is an explicit
`task web:icons-check`.

## Why it lives here

`client/tool/` is where client build-time tooling lives (`build_app_shell_cache.dart`), and
this is client tooling that writes into `client/web/`. It is Node rather than Dart because
the job is rasterising a PDF: `pdfjs-dist` + a Skia canvas has no Dart equivalent, and the
alternative — a system `pdftocairo`/ImageMagick pipeline — would trade a lockfile for an
unpinned, unreproducible host binary. Keeping the master in the same folder as the only
script that reads it makes the provenance self-evident.

This package is deliberately **excluded** from `task web:lint` / `test` / `build`'s package
discovery (like `client/e2e/`): it pulls a large platform-specific native binary and is
design-time tooling, not part of the build.
