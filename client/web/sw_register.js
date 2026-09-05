/*
 * Registers the app-shell service worker (#619, FR-OF-1, FR-PL-1, D-10).
 *
 * A separate FILE rather than an inline <script> in index.html: `nginx.conf`
 * ships `script-src 'self' 'wasm-unsafe-eval'` with no `'unsafe-inline'`
 * (Report-Only until #89 enforces it), so an inline registration snippet would
 * be blocked the moment that policy starts enforcing — silently taking the
 * offline shell with it.
 *
 * Separate from `flutter_bootstrap.js` too: that file is deliberately kept to
 * what Flutter generates plus one `config` addition (#620), and
 * `client/test/fonts_local_fallback_test.dart` pins that property. Registration
 * is ours, so it lives in our own file.
 *
 * `service_worker.js` is document-relative, so it resolves under the page's
 * base href — `/` in every build in this repo, matching the reasoning already
 * recorded in `flutter_bootstrap.js` and `nginx.conf`. That gives the worker
 * the `/` scope it needs to answer navigations for every go_router route.
 *
 * Registration is deferred to `load` so the precache download never competes
 * with the boot the user is actually waiting on (NFR-PER-1); the worker claims
 * the page as soon as it activates, so this visit is still covered.
 *
 * A failure here is logged and swallowed on purpose: no service worker means no
 * offline shell, but the app itself must still run — an unhandled rejection at
 * boot would be a worse outcome than the degradation it reports.
 */
if ("serviceWorker" in navigator) {
  window.addEventListener("load", async () => {
    // Tell whichever worker currently CONTROLS this page what the page loaded,
    // so it can store the RUNTIME-tier resources it never got the chance to
    // see. Deliberately `controller`, not `registration.active`, and
    // deliberately re-sent on every `controllerchange`:
    //
    //  - FIRST visit: no worker controls the page while it boots, so the engine
    //    is fetched with nothing in the way. The new worker calls `claim()` at
    //    the end of `activate`, `controllerchange` fires, and this reports.
    //  - UPDATE visit: the PREVIOUS build's worker is active and controlling, so
    //    `ready` resolves against it and `registration.active` is the OLD
    //    worker. Reporting only there would warm a cache that is about to be
    //    swept: the new worker installs behind the page, claims it, and its
    //    fresh cache would hold the precache tier and no engine — reopening,
    //    on every single release, exactly the gap this handshake closes.
    //    `controllerchange` fires on that swap too, so the new worker is told.
    //
    // The worker treats the list as an untrusted hint and stores only paths
    // already in its own manifest.
    const reportBootResources = () => {
      navigator.serviceWorker.controller?.postMessage({
        type: "bkit:boot-resources",
        urls: performance
          .getEntriesByType("resource")
          .map((entry) => entry.name)
          .filter((name) => name.startsWith(`${window.location.origin}/`)),
      });
    };
    navigator.serviceWorker.addEventListener("controllerchange", reportBootResources);

    try {
      await navigator.serviceWorker.register("service_worker.js", {
        // Never let an HTTP cache answer the update check for the worker script
        // or anything it imports. `nginx.conf` already sends
        // `Cache-Control: no-cache` for everything, so this changes nothing
        // today — it just stops a future header change from quietly freezing
        // every installed client on an old shell, which is the failure mode this
        // whole file exists to prevent.
        updateViaCache: "none",
      });

      // Covers the case `controllerchange` does not: a page that was ALREADY
      // controlled when it loaded and whose worker is not replaced this visit.
      // Its engine requests did go through the worker, so this is usually a
      // no-op — but it is what makes the report unconditional rather than
      // dependent on a swap happening.
      await navigator.serviceWorker.ready;
      reportBootResources();
    } catch (error) {
      console.warn("[beekeepingit] app-shell service worker registration failed", error);
    }
  });
}
