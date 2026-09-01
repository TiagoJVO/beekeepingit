import { test, expect, Page } from "@playwright/test";
import { enableSemantics, submitIdpCredentials } from "./helpers";

/**
 * DGAV section end-to-end (#296/#298, FR-AP-9/FR-AP-10):
 *   log in → open DGAV → set the organization's registration
 *   number → record a stock declaration → assert it lists → **assert a fresh
 *   client downloads it** → delete it again.
 *
 * WHY THIS SPEC EXISTS, AND WHY THE FRESH-CLIENT STEP IS THE POINT.
 *
 * `stock_declarations` is a brand-new table with a brand-new Sync Rules entry
 * (`infra/helm/beekeepingit/charts/powersync/values.yaml`). Nothing else in the
 * test suite exercises that entry: the Go integration tests prove the service
 * stores and applies declarations, and the Flutter widget/repository tests prove
 * the client reads and writes its LOCAL table — but a sync-rules entry that is
 * missing, misspelled or filtered wrong fails **silently**, exactly the way
 * `notes` did when #33 rewrote the apiaries entry from `SELECT *` to an explicit
 * column list (see e2e/README.md). The row simply never arrives, and every
 * local-only test still passes because the device that wrote it has it locally.
 *
 * A fresh browser context has an empty local SQLite, so it can only show a
 * declaration that PowerSync actually **downloaded**. That single assertion is
 * the reason this file is worth its runtime.
 *
 * The registration number gets the same treatment for the same reason: it is a
 * new column on an EXPLICIT sync-rules column list, which is precisely the shape
 * that silently stays NULL on a device that did not write it.
 *
 * CLEANUP. Unlike apiaries, declarations have no REST surface (sync only, like
 * apiary_counters), so `afterAll` cannot delete by id the way slice.spec.ts
 * does. The delete step at the end of the main test IS the teardown — and it
 * doubles as coverage of the one lifecycle operation a counter deliberately
 * does not have (a mis-entered declaration must be removable, FR-AP-10).
 */

// A tall viewport so nothing on the DGAV screen sits below the fold.
//
// Same root cause as goToDgav's comment below: Flutter web renders to canvas,
// so a Playwright coordinate click only reaches the widget when the canvas
// hit-test target is actually on screen. Rather than sprinkle scroll dances
// through the test, give the page room so every control this spec touches is
// visible — which is also how a beekeeper on a real device sees this short
// screen. Width stays desktop-default; only the height changes.
test.use({ viewport: { width: 1280, height: 2200 } });

const TEST_USER = process.env.E2E_USER ?? "test.beekeeper@beekeepingit.local";
const TEST_PASS = process.env.E2E_PASS ?? "dev-password123";

// Unique per run so a longer-lived environment doesn't accumulate collisions,
// and so the fresh-client assertion cannot pass on a declaration left behind by
// an earlier run. Kept inside the column's 50-char cap (FR-AP-9).
const registrationNumber = `PT-E2E-${Date.now()}`;

async function login(page: Page) {
  await submitIdpCredentials(page, TEST_USER, TEST_PASS);
  // After login the app lands on the Tasks tab (D-29, #427), not the apiaries
  // list. The OIDC callback is a full page load that re-bootstraps Flutter plus
  // the token exchange, so allow generously for a cold stack.
  await page.waitForURL(/\/todos/, { timeout: 60_000 });
  await enableSemantics(page);
  await expect(page.getByRole("heading", { name: "Todos" })).toBeVisible({ timeout: 30_000 });
}

/**
 * Opens the DGAV screen.
 *
 * In the app the section is reachable only from Account by design (#298:
 * everything DGAV is advisory, so it never interrupts the field flows) — there
 * is deliberately no tab, banner or deep link. That entry point is asserted in
 * account_screen_test.dart; see the comment in the body for why this spec
 * navigates by URL instead of clicking it.
 */
async function goToDgav(page: Page) {
  // Straight to the route, NOT via the Account button.
  //
  // The button is real and covered by a widget test
  // (account_screen_test.dart: every member sees the DGAV action). What it
  // is NOT is reliably clickable from headless Playwright: Flutter web
  // renders to canvas and exposes a parallel DOM a11y tree, so a coordinate
  // click only lands if the canvas hit-test target is under that point — and
  // the DGAV action sits below Profile/Sync/Notifications/Security on the
  // account screen. Two CI runs proved it: Playwright reported the click as
  // successful, the failure snapshot showed the app still on Account with
  // `button "DGAV"` right there, and dispatching a DOM click on the
  // semantics node did not help either.
  //
  // Rather than keep guessing at a canvas-tap workaround, each assertion now
  // sits where it can actually be proven: the entry point's existence in a
  // widget test, and everything only a live cluster can show — the sync-rules
  // entry, download convergence — here. Navigating by URL is a real user
  // action too (the route is bookmarkable), and it exercises the same router
  // and screen.
  await page.goto("/dgav");
  await page.waitForURL(/\/dgav/, { timeout: 30_000 });
  await enableSemantics(page);
  // The advisory framing is part of the requirement, not decoration (D-19 §7:
  // the app files nothing with DGAV). Assert it renders rather than trusting it.
  await expect(page.getByText(/never files anything for you/)).toBeVisible({
    timeout: 30_000,
  });
}

test("DGAV: set the registration number, record a declaration, and converge on a fresh client", async ({
  page,
  browser,
}) => {
  await login(page);
  await goToDgav(page);

  // ── The organization's registration number (FR-AP-9, #296) ────────────
  // Editing this is an admin-only REST PATCH, not a synced write — the one
  // thing in this screen that needs connectivity (the value is READ offline
  // from the cached organization). The seeded e2e user is their org's admin
  // (D-3: the creator is the first admin), so the field is enabled.
  const numberField = page.getByRole("textbox", {
    name: /Organization registration number/,
  });
  await expect(numberField).toBeVisible({ timeout: 30_000 });
  await numberField.fill(registrationNumber);
  await page.getByRole("button", { name: "Save" }).click();
  await expect(page.getByText("Registration number saved")).toBeVisible({
    timeout: 30_000,
  });

  // ── Record a declaration (FR-AP-10, #298) ─────────────────────────────
  // The record action opens a dialog rather than writing immediately: a
  // beekeeper files with DGAV first and logs it here after, so the date is
  // editable and must not be assumed to be today. Here we accept the default.
  await page.getByRole("button", { name: "Record declaration" }).first().click();
  await enableSemantics(page);
  await expect(page.getByRole("textbox", { name: /Note \(optional\)/ })).toBeVisible({
    timeout: 30_000,
  });
  await page
    .getByRole("textbox", { name: /Note \(optional\)/ })
    .fill("e2e: filed via the IFAP portal");
  await page.getByRole("button", { name: "Record", exact: true }).click();
  await expect(page.getByText("Declaration recorded")).toBeVisible({ timeout: 30_000 });

  // The log now shows it. The row reads "<localized date> — N hives"; assert on
  // the hive-count half plus the apiary-count subtitle rather than pinning a
  // formatted date, which legitimately varies with the browser locale.
  const declarationRow = page.getByText(/\d+ hives?$/);
  await expect(declarationRow.first()).toBeVisible({ timeout: 30_000 });

  // ── Nudge the flush, exactly as slice.spec.ts does ────────────────────
  // The connectivity gate (#55, FR-OF-3) can sit in backoff after a fresh
  // login, so a queued write may not have gone out yet. "Sync now" bypasses the
  // gate and makes the fresh-client assertion below deterministic rather than a
  // race with the backoff.
  await page.goBack();
  await enableSemantics(page);
  await page.getByRole("button", { name: "Sync now" }).click();

  // ── A fresh client downloads both (the sync-rules guard) ──────────────
  // THE point of this spec. An empty local SQLite can only show these if
  // PowerSync downloaded them — so this fails loudly if the
  // `apiaries.stock_declarations` bucket entry or the `dgav_registration_number`
  // column is missing from the Sync Rules, the one failure mode that is
  // otherwise completely silent.
  //
  // 60s, matching slice.spec.ts: a fresh client's first full-bucket download is
  // gated by the same probe/backoff and legitimately needs more than 30s under
  // CI load.
  const fresh = await browser.newContext();
  try {
    const p2 = await fresh.newPage();
    await login(p2);
    await goToDgav(p2);

    // The registration number replicated (FR-AP-9) — it reaches this client
    // through the organization REST read, and groups the declaration below.
    await expect(p2.getByText(registrationNumber).first()).toBeVisible({
      timeout: 60_000,
    });

    // The declaration itself replicated (FR-AP-10) — this is the assertion the
    // new sync-rules entry lives or dies by.
    await expect(p2.getByText(/\d+ hives?$/).first()).toBeVisible({ timeout: 60_000 });
  } finally {
    await fresh.close();
  }

  // ── Delete it again: teardown, and the lifecycle a counter lacks ──────
  // Declarations have no REST surface, so this UI delete is the only teardown
  // available — and it covers FR-AP-10's "a mis-entered declaration must be
  // removable", which apiary_counters deliberately does not allow.
  await goToDgav(page);
  await page.getByRole("button", { name: "Delete declaration" }).first().click();
  await expect(page.getByText("No declarations recorded yet.")).toBeVisible({
    timeout: 30_000,
  });
});
