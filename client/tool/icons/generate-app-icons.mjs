#!/usr/bin/env node
//
// Regenerate the branded PWA icon set from the committed vector master.
//
//   Issue: #682 (provenance) / #233, #681 (the shipped set)
//   Requirements: FR-PL-1 · Decisions: D-10 (PWA-first)
//
// Inputs : ./melargil-logo-master.pdf  (the Melargil brand master — see README.md)
// Outputs: ../../web/icons/Icon-{192,512}.png
//          ../../web/icons/Icon-maskable-{192,512}.png
//          ../../web/favicon.png
//
// Usage:
//   npm run generate     rewrite the icon set in client/web/
//   npm run check        regenerate in memory and fail if the committed PNGs differ
//   node generate-app-icons.mjs [--check] [--out <dir>] [--master <pdf>]
//
// Every geometry constant below is load-bearing: the committed PNGs are the
// byte-for-byte output of this file at these values with these pinned
// dependency versions. Changing any of them changes the shipped artwork, so
// `npm run check` fails until the regenerated set is committed alongside.
//
// See README.md for why each constant is what it is.

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";
import { createCanvas, DOMMatrix, Image, ImageData, Path2D } from "@napi-rs/canvas";

// ---------------------------------------------------------------------------
// pdf.js draws vector paths through the browser canvas APIs. Node has no DOM,
// and pdf.js only *warns* when they are absent before silently mis-rendering
// every path — you get a plausible-looking but wrong raster, not an error.
// Supplying them from @napi-rs/canvas is mandatory, and it has to happen
// BEFORE pdf.js is loaded. Hence the runtime `require` below rather than a
// static `import`: ESM imports are hoisted and would run first.
// ---------------------------------------------------------------------------
globalThis.DOMMatrix ??= DOMMatrix;
globalThis.Path2D ??= Path2D;
globalThis.ImageData ??= ImageData;
const pdfjsLib = createRequire(import.meta.url)("pdfjs-dist/legacy/build/pdf.js");

const HERE = path.dirname(fileURLToPath(import.meta.url));

/** Rasterisation scale for page 1 of the master (MediaBox [-1 -1 220.7698 99.3446], i.e. 221.77 x 100.34 pt -> 5323x2409). */
const RENDER_SCALE = 24;

/** The bee is the only amber artwork on the page; the wordmark is near-black. */
const AMBER = { minAlpha: 128, minR: 200, minG: 110, maxG: 220, maxB: 110 };

/** Breathing room around the bee's bounding box, as a fraction of its longest side. */
const PAD_FRACTION = 0.02;

/** Anything at least this opaque and darker than this on every channel is wordmark, not bee. */
const INK = { minAlpha: 8, maxChannel: 140 };

/** Pixels at least this opaque are part of the silhouette. */
const SILHOUETTE_MIN_ALPHA = 8;

/** Brand amber — also the manifest's `theme_color`/`background_color`. */
const BRAND_AMBER = "#F9A825";

/**
 * The shipped set. `fill` is the fraction of the canvas's shorter side the bee
 * spans: the plain icons fill the square, the maskable pair stays inside
 * Android's circle/squircle safe zone.
 */
const OUTPUTS = [
  { file: "icons/Icon-192.png", size: 192, fill: 0.86 },
  { file: "icons/Icon-512.png", size: 512, fill: 0.86 },
  { file: "icons/Icon-maskable-192.png", size: 192, fill: 0.62 },
  { file: "icons/Icon-maskable-512.png", size: 512, fill: 0.62 },
  { file: "favicon.png", size: 32, fill: 0.92 },
];

function parseArgs(argv) {
  const opts = {
    check: false,
    out: path.resolve(HERE, "..", "..", "web"),
    master: path.resolve(HERE, "melargil-logo-master.pdf"),
  };
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case "--check":
        opts.check = true;
        break;
      case "--out":
        opts.out = path.resolve(argv[++i]);
        break;
      case "--master":
        opts.master = path.resolve(argv[++i]);
        break;
      default:
        throw new Error(`unknown argument: ${argv[i]}`);
    }
  }
  return opts;
}

/** Rasterise page 1 of the master onto a transparent canvas. */
async function renderMaster(master) {
  const data = new Uint8Array(fs.readFileSync(master));
  const pdf = await pdfjsLib.getDocument({ data, disableFontFace: true }).promise;
  const page = await pdf.getPage(1);
  const viewport = page.getViewport({ scale: RENDER_SCALE });
  const canvas = createCanvas(Math.ceil(viewport.width), Math.ceil(viewport.height));
  await page.render({
    canvasContext: canvas.getContext("2d"),
    viewport,
    background: "rgba(0,0,0,0)",
  }).promise;
  return canvas;
}

/**
 * Bounding box of the amber bee, padded by PAD_FRACTION of its longest side and
 * clamped to the page.
 */
function beeBounds(page) {
  const { width, height } = page;
  const px = page.getContext("2d").getImageData(0, 0, width, height).data;
  let x0 = Infinity;
  let y0 = Infinity;
  let x1 = -1;
  let y1 = -1;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 4;
      const [r, g, b, a] = [px[i], px[i + 1], px[i + 2], px[i + 3]];
      if (
        a > AMBER.minAlpha &&
        r > AMBER.minR &&
        g > AMBER.minG &&
        g < AMBER.maxG &&
        b < AMBER.maxB
      ) {
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
  }
  if (x1 < 0) {
    throw new Error(
      "no amber pixels found — either the master changed or pdf.js mis-rendered " +
        "the page (check the DOMMatrix/Path2D/ImageData globals above).",
    );
  }
  const pad = Math.round(Math.max(x1 - x0, y1 - y0) * PAD_FRACTION);
  x0 = Math.max(0, x0 - pad);
  y0 = Math.max(0, y0 - pad);
  x1 = Math.min(width - 1, x1 + pad);
  y1 = Math.min(height - 1, y1 + pad);
  return { x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1 };
}

/** Crop the bee out of the rendered page, erasing any wordmark the pad caught. */
function cropBee(page, box) {
  const canvas = createCanvas(box.width, box.height);
  const cx = canvas.getContext("2d");
  cx.drawImage(page, box.x, box.y, box.width, box.height, 0, 0, box.width, box.height);
  const frame = cx.getImageData(0, 0, box.width, box.height);
  const px = frame.data;
  // The pad can reach into the wordmark below the bee. The wordmark is
  // near-black; the bee anti-aliases amber-to-transparent and never goes dark,
  // so dropping dark pixels removes the glyphs without eroding the bee's edge.
  for (let i = 0; i < px.length; i += 4) {
    if (
      px[i + 3] > INK.minAlpha &&
      px[i] < INK.maxChannel &&
      px[i + 1] < INK.maxChannel &&
      px[i + 2] < INK.maxChannel
    ) {
      px[i + 3] = 0;
    }
  }
  cx.putImageData(frame, 0, 0);
  return canvas;
}

/**
 * Flat-white silhouette of the cropped bee, anti-aliased alpha preserved.
 *
 * Deliberately a second canvas rather than one fused pass over `cropBee`'s
 * pixels: the `drawImage` round-trip trips the canvas's premultiplied-alpha
 * storage, and the committed PNGs are the output of that exact sequence.
 */
function whiten(bee) {
  const canvas = createCanvas(bee.width, bee.height);
  const cx = canvas.getContext("2d");
  cx.drawImage(bee, 0, 0);
  const frame = cx.getImageData(0, 0, bee.width, bee.height);
  const px = frame.data;
  for (let i = 0; i < px.length; i += 4) {
    if (px[i + 3] > SILHOUETTE_MIN_ALPHA) {
      px[i] = 255;
      px[i + 1] = 255;
      px[i + 2] = 255;
    }
  }
  cx.putImageData(frame, 0, 0);
  return canvas;
}

/** Centre `bee` on a `size`-square amber tile, spanning `fill` of the canvas. */
function renderIcon(bee, size, fill) {
  const canvas = createCanvas(size, size);
  const cx = canvas.getContext("2d");
  cx.fillStyle = BRAND_AMBER;
  cx.fillRect(0, 0, size, size);
  const scale = (size * fill) / Math.max(bee.width, bee.height);
  const w = bee.width * scale;
  const h = bee.height * scale;
  cx.drawImage(bee, (size - w) / 2, (size - h) / 2, w, h);
  return canvas.toBuffer("image/png");
}

/**
 * True when two PNG buffers decode to identical pixels.
 *
 * Deliberately NOT a byte comparison. The PNG encoder may emit slightly
 * different bytes for the same raster on different platforms, and it does:
 * Windows x64 and Linux x86_64 renders of this artwork are pixel-identical but
 * 1-2 bytes apart once encoded. Gating on bytes would fail CI for artwork that
 * is perfectly correct (#687); the raster is the invariant worth gating.
 */
function samePixels(a, b) {
  const pixels = (buf) => {
    const img = new Image();
    img.src = buf;
    const c = createCanvas(img.width, img.height);
    const cx = c.getContext("2d");
    cx.drawImage(img, 0, 0);
    return {
      w: img.width,
      h: img.height,
      data: cx.getImageData(0, 0, img.width, img.height).data,
    };
  };
  const A = pixels(a);
  const B = pixels(b);
  if (A.w !== B.w || A.h !== B.h) return false;
  if (A.data.length !== B.data.length) return false;
  for (let i = 0; i < A.data.length; i++) if (A.data[i] !== B.data[i]) return false;
  return true;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));

  const page = await renderMaster(opts.master);
  console.log(`rendered master at ${page.width}x${page.height} (scale ${RENDER_SCALE})`);
  const box = beeBounds(page);
  console.log(`bee bounding box ${box.width}x${box.height} at ${box.x},${box.y}`);
  const bee = whiten(cropBee(page, box));

  let drift = 0;
  for (const { file, size, fill } of OUTPUTS) {
    const png = renderIcon(bee, size, fill);
    const target = path.join(opts.out, file);
    if (opts.check) {
      const committed = fs.existsSync(target) ? fs.readFileSync(target) : null;
      if (committed === null) {
        drift++;
        console.error(`  DRIFT  ${file} — missing`);
      } else if (samePixels(committed, png)) {
        const note =
          committed.length === png.length
            ? ""
            : ` (re-encoded: ${committed.length} vs ${png.length} bytes)`;
        console.log(`  ok     ${file}${note}`);
      } else {
        drift++;
        console.error(`  DRIFT  ${file} — the rendered artwork differs`);
      }
    } else {
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.writeFileSync(target, png);
      console.log(`  wrote  ${file} (${size}x${size}, fill ${fill}, ${png.length} bytes)`);
    }
  }

  if (drift > 0) {
    console.error(
      `\n${drift} file(s) differ from this generator's output. ` +
        "Run `npm run generate` and commit the result, or restore the icons.",
    );
    process.exitCode = 1;
  } else if (opts.check) {
    console.log("\nevery committed icon matches the generator pixel for pixel.");
  }
}

await main();
