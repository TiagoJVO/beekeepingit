// This file reads text off disk and never renders anything, so it opts out of
// the suite-wide jsdom environment. That is not a micro-optimization: standing
// up jsdom for it costs ~6s of the ~2.5s this whole file otherwise takes, and it
// is load on the same worker pool as the RTL specs, whose `findBy*` timeouts are
// already the suite's flakiest edge. `node` also makes `import.meta.url` a real
// file: URL, which is what lets the reads below be cwd-independent.
// @vitest-environment node
import { existsSync, readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

/**
 * Guards the serving policy in `admin/nginx.conf` (#677, NFR-ROL-2, NFR-PER-1,
 * NFR-SEC-1).
 *
 * The admin app has no runtime that could assert its own response headers — it
 * is a static bundle handed to nginx by `admin/Dockerfile`, and the only place
 * the policy exists is that config file. The client bundle has the same problem
 * and solves it the same way (`client/test/nginx_compression_test.dart`): a
 * seconds-long unit test over the config TEXT, guarding the properties whose
 * failure mode is silent — `nginx -t` green, pod Ready, nothing red anywhere.
 *
 * Two such properties live here.
 *
 *  - **The split cache policy must stay driven by an http-level `map`.**
 *    `index.html` must revalidate (`no-cache`) so a release is picked up on the
 *    next load, while Vite's CONTENT-HASHED `assets/*` may be cached forever
 *    (`max-age=31536000, immutable`) because a new build emits new filenames.
 *    Two values for one header is exactly the situation that tempts a
 *    `location /assets/ { add_header … }` — see the next point for why that is
 *    a trap. The `map` keeps every `add_header` at ONE level.
 *
 *  - **No `location {}` may set Cache-Control itself (#89).** In nginx,
 *    `add_header` is inherited from the enclosing level ONLY IF the current
 *    level declares none of its own: a single `add_header` inside a `location`
 *    CANCELS every server-level one. One there would silently strip
 *    `X-Content-Type-Options`, `Referrer-Policy`, `X-Frame-Options` and the
 *    Report-Only CSP from every response served through that location, and
 *    nothing else in this repo would notice.
 *
 * A live probe against the running container proves the OUTCOME and is the
 * stronger check where it can run — it is also the only thing that could catch
 * a Cache-Control injected or duplicated upstream of this pod. That half is
 * tracked on #706 (the admin app has no equivalent of
 * `client/e2e/tests/cache-headers.spec.ts` yet); this is the version that costs
 * a second and runs on every `npm test`.
 */

// Resolved against THIS FILE, not the working directory, so the test does not
// silently depend on being launched from `admin/` (an IDE runner started at the
// repo root would otherwise ENOENT on a policy test, which reads as a policy
// failure). `client/test/nginx_compression_test.dart` uses the cwd-relative
// form; this is the same idea without that coupling.
const packageFile = (name: string) => new URL(`../${name}`, import.meta.url);
const readPackageFile = (name: string) => readFileSync(packageFile(name), "utf8");

// Every `#` comment is stripped, so an assertion can never be satisfied by the
// (extensive) prose rationale in the file — only by a real directive. No value
// in this config contains a literal `#`.
const directives = readPackageFile("nginx.conf")
  .split("\n")
  .map((line) => line.replace(/#.*$/, "").trim())
  .filter((line) => line.length > 0)
  .join("\n");

// `map` is an http-level directive, so everything before `server {` is the
// http level this file contributes (it is COPYed to /etc/nginx/conf.d/, which
// the stock nginx.conf includes from inside `http {}`).
const serverStart = directives.indexOf("server {");
const httpLevel = directives.slice(0, serverStart);
const serverBlock = directives.slice(serverStart);

// Everything in the server block before the FIRST `location` is server level;
// everything from there on is inside a location. Crude, and deliberately so —
// it needs no nginx parser, and it errs toward calling text "inside a location",
// which is the direction that fails loudly rather than silently.
const firstLocation = serverBlock.indexOf("location ");
const serverLevel = firstLocation === -1 ? serverBlock : serverBlock.slice(0, firstLocation);
const locationBlocks = firstLocation === -1 ? "" : serverBlock.slice(firstLocation);

// The same treatment for the TypeScript config the `immutable` premise rests
// on: strip comments first, or documenting the constraint below would trip the
// tripwire that enforces it.
const viteConfig = readPackageFile("vite.config.ts")
  .replace(/\/\*[\s\S]*?\*\//g, "")
  .replace(/^\s*\/\/.*$/gm, "");

describe("the admin bundle's cache policy (#677)", () => {
  it("parses as one http level plus one server block", () => {
    // Guards every slice below: without this, a missing `server {` makes
    // indexOf return -1 and `slice(0, -1)` quietly hand every later assertion a
    // string that is off by one character instead of failing.
    expect(serverStart, "nginx.conf no longer contains a `server {` block").toBeGreaterThan(-1);
  });

  it("selects Cache-Control from an http-level map, not a second location block", () => {
    expect(
      httpLevel,
      "the $cache_control map must sit at http level (outside `server {}`) — nginx rejects " +
        "`map` inside a server block",
    ).toContain("map $uri $cache_control {");
  });

  it("revalidates everything by default", () => {
    // `index.html`, the SPA fallback, and anything else served from the bundle
    // root carry stable names whose bytes change every release, so the default
    // must be revalidate-before-reuse. `no-cache` does NOT mean "don't store":
    // nginx's ETag/Last-Modified still turn repeat loads into cheap 304s.
    expect(httpLevel).toMatch(/default\s+"no-cache";/);
  });

  it("serves the content-hashed assets immutable for a year", () => {
    // Vite emits `assets/index-<hash>.js` / `assets/index-<hash>.css` — a new
    // build is a new URL, so the bytes behind one of these names can never
    // change and `immutable` has a genuinely safe target here (unlike the
    // Flutter client, whose bundle has NO hashed names at all — #621).
    expect(httpLevel).toMatch(/"~\^\/assets\/"\s+"max-age=31536000, immutable";/);
  });

  it("keeps the premise of `immutable` true: Vite's default hashed output", () => {
    // `immutable` is the one directive with NO reload escape — an unhashed file
    // under `/assets/` is pinned in browser caches for a year and only a URL
    // change can free it. That premise is Vite's DEFAULT (`build.assetsDir` =
    // "assets", hashed `entryFileNames`/`chunkFileNames`/`assetFileNames`, and
    // `base` = "/"), and this app overrides none of it.
    expect(
      viteConfig,
      "admin/vite.config.ts now overrides Vite's output naming or base path — confirm " +
        "assets/* is still content-hashed and still served from /assets/ before nginx.conf " +
        "keeps serving it `immutable` (#677)",
    ).not.toMatch(/assetsDir|rollupOptions|entryFileNames|chunkFileNames|assetFileNames|base:/);
  });

  it("keeps the premise of `immutable` true: nothing unhashed is copied into /assets/", () => {
    // The cheapest way to break the premise needs no vite.config.ts change at
    // all: Vite copies `public/` VERBATIM to the bundle root, so a file at
    // `admin/public/assets/foo.js` is served at `/assets/foo.js` with a stable
    // name — and pinned for a year. `admin/public/` does not exist today.
    expect(
      existsSync(packageFile("public/assets")),
      "admin/public/assets/ would be copied verbatim into the bundle's /assets/ prefix, " +
        "putting UNHASHED files behind `max-age=31536000, immutable` (#677)",
    ).toBe(false);
  });

  it("applies the policy with a single server-level add_header", () => {
    expect(serverLevel).toContain("add_header Cache-Control $cache_control always;");
  });
});

describe("nginx's add_header inheritance trap (#89)", () => {
  it("declares every security header at server level", () => {
    expect(serverLevel).toContain("add_header X-Content-Type-Options nosniff always;");
    expect(serverLevel).toContain(
      "add_header Referrer-Policy strict-origin-when-cross-origin always;",
    );
    expect(serverLevel).toContain("add_header X-Frame-Options DENY always;");
    expect(serverLevel).toContain("add_header Content-Security-Policy-Report-Only ");
  });

  it("lets no location block set headers of its own", () => {
    // THE canary. If this ever fails, the fix is almost never "add the missing
    // headers to that location too" — it is to express the difference as a
    // server-level `map` (as the Cache-Control split above does), so there
    // stays exactly ONE place headers are declared and no second list to keep
    // in sync.
    //
    // `expires` is matched too, and it is the subtler half: it is
    // ngx_http_headers_module writing Cache-Control by a DIFFERENT route, so it
    // does not cancel inheritance — the security headers survive, this canary
    // would stay green if it only looked for `add_header`, and the response
    // quietly carries TWO conflicting Cache-Control headers.
    expect(
      locationBlocks,
      "a location{} may not set headers: an `add_header` there cancels inheritance of ALL " +
        "server-level add_header directives — X-Content-Type-Options, Referrer-Policy, " +
        "X-Frame-Options, the Report-Only CSP and Cache-Control would all silently vanish for " +
        "that location — and an `expires` there emits a SECOND, conflicting Cache-Control (#89)",
    ).not.toMatch(/add_header|expires\s/);
  });
});
