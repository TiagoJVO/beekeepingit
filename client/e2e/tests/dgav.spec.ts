import { test, expect, Locator, Page } from "@playwright/test";
import { enableSemantics, submitIdpCredentials } from "./helpers";

/**
 * DGAV section end-to-end (#296/#298, FR-AP-9/FR-AP-10):
 *   log in → open Account → open DGAV → set the organization's registration
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
 * Taps a Flutter-web semantics node by dispatching a DOM click on the node
 * itself, rather than Playwright's coordinate click.
 *
 * WHY, because this is a real deviation from the rest of the suite. Flutter
 * web renders to canvas and exposes a PARALLEL DOM accessibility tree. A
 * coordinate click only reaches the widget if the canvas hit-test target is
 * under that point — so for a control below the fold, Playwright happily finds
 * the semantics node, auto-scrolls the DOM, reports the click as successful,
 * and the tap lands nowhere. That is exactly how this spec first failed: the
 * Account screen's DGAV button (below Profile/Sync/Notifications/Security)
 * clicked "fine" and the app never navigated.
 *
 * Flutter's own engine attaches a `click` listener to a tappable semantics
 * node (web_ui/.../semantics/tappable.dart) and routes it to the widget's tap
 * action, so dispatching the DOM click drives the SAME path a real assistive
 * -technology activation would — no coordinates involved. The scroll first is
 * belt-and-braces so the node is realized before we touch it.
 *
 * The rest of the suite gets away with plain .click() because everything it
 * touches is above the fold. The one existing bottom-of-Account click (the
 * logout test) is `test.fixme`, so there was no working precedent to copy.
 */
async function tapSemantic(page: Page, locator: Locator) {
  await expect(locator).toBeVisible({ timeout: 30_000 });
  await locator.scrollIntoViewIfNeeded();
  await locator.evaluate((el: HTMLElement) => el.click());
}

/**
 * Account → DGAV. The DGAV section is reachable ONLY from Account by design
 * (#298: everything DGAV is advisory, so it never interrupts the field flows) —
 * there is deliberately no tab, banner or deep link, which is why this helper is
 * the only way in.
 */
async function goToDgav(page: Page) {
  await page.getByRole("button", { name: "Account settings" }).click();
  await enableSemantics(page);
  await expect(page.getByRole("heading", { name: "Account settings" })).toBeVisible({
    timeout: 30_000,
  });
  await tapSemantic(page, page.getByRole("button", { name: "DGAV", exact: true }));
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
  await tapSemantic(page, page.getByRole("button", { name: "Save" }));
  await expect(page.getByText("Registration number saved")).toBeVisible({
    timeout: 30_000,
  });

  // ── Record a declaration (FR-AP-10, #298) ─────────────────────────────
  // The record action opens a dialog rather than writing immediately: a
  // beekeeper files with DGAV first and logs it here after, so the date is
  // editable and must not be assumed to be today. Here we accept the default.
  await tapSemantic(page, page.getByRole("button", { name: "Record declaration" }).first());
  await enableSemantics(page);
  await expect(page.getByRole("textbox", { name: /Note \(optional\)/ })).toBeVisible({
    timeout: 30_000,
  });
  await page
    .getByRole("textbox", { name: /Note \(optional\)/ })
    .fill("e2e: filed via the IFAP portal");
  await tapSemantic(page, page.getByRole("button", { name: "Record", exact: true }));
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
  await tapSemantic(page, page.getByRole("button", { name: "Sync now" }));

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
  await tapSemantic(page, page.getByRole("button", { name: "Delete declaration" }).first());
  await expect(page.getByText("No declarations recorded yet.")).toBeVisible({
    timeout: 30_000,
  });
});
