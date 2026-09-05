import { randomUUID } from "node:crypto";
import { test, expect, Page } from "@playwright/test";
import { apiJson, enableSemantics, submitIdpCredentials } from "./helpers";

/**
 * Registration number + stock declarations, end to end (#296/#298,
 * FR-AP-9/FR-AP-10):
 *   log in → Account → **Organization details** → set the organization's
 *   registration number → save → Account → **Stock declarations** → record a
 *   declaration (date + note) → assert it lists → **assert a fresh client
 *   downloads both** → delete the declaration again.
 *
 * WHY THIS SPEC EXISTS, AND WHY THE FRESH-CLIENT STEP IS THE POINT.
 *
 * `stock_declarations` is a table with its own PowerSync Sync Rules entry
 * (`infra/helm/beekeepingit/charts/powersync/values.yaml`), and
 * `registration_number` is a column on the **explicit** column list of the
 * `apiaries.apiaries` entry next to it. Nothing else in the test suite
 * exercises either: the Go integration tests prove the service stores and
 * applies declarations, and the Flutter widget/repository tests prove the
 * client reads and writes its LOCAL tables — but a sync-rules entry that is
 * missing, misspelled or filtered wrong fails **silently**. The row simply
 * never arrives, the column just stays NULL, and every local-only test still
 * passes because the device that wrote the value has it locally. That is
 * exactly what happened to `notes` when #33 rewrote the apiaries entry from
 * `SELECT *` to an explicit column list (see e2e/README.md).
 *
 * A fresh browser context has an empty local SQLite, so it can only show a
 * declaration that PowerSync actually **downloaded**. That single assertion is
 * the reason this file is worth its runtime — everything before it exists to
 * set that assertion up, and everything after it is teardown.
 *
 * CLEANUP. Declarations have no REST surface (sync only, like apiary_counters),
 * so `afterAll` cannot delete one by id the way slice.spec.ts deletes its
 * apiary. The UI delete at the end of the test IS the teardown — and it doubles
 * as coverage of the one lifecycle operation a counter deliberately lacks (a
 * mis-entered declaration must be removable, FR-AP-10). The apiary this spec
 * creates for itself (below) does have a REST surface, so that one is deleted
 * in `afterAll` like slice's.
 */

// A tall viewport, applied to BOTH contexts this spec opens (see the
// fresh-client block for why the second one has to opt in explicitly).
//
// Flutter web renders to canvas, so a Playwright coordinate click only reaches
// the widget when the hit-test target is genuinely on screen — an off-screen
// control reports a successful click while the tap goes nowhere. The Account
// screen is long and BOTH entry points this spec uses ("Organization details",
// "Stock declarations") sit near its bottom, below Profile/Sync/Notifications/
// Security. At the default 720px height the click was reported as successful
// and landed nowhere (two CI runs, same failure snapshot each time: still on
// Account, the button right there in the semantics tree). Give the page room
// instead of sprinkling scroll dances through the test. Width stays
// desktop-default; only the height changes.
const TALL_VIEWPORT = { width: 1280, height: 3000 };
test.use({ viewport: TALL_VIEWPORT });

const TEST_USER = process.env.E2E_USER ?? "test.beekeeper@beekeepingit.local";
const TEST_PASS = process.env.E2E_PASS ?? "dev-password123";

// Unique per run so a longer-lived environment doesn't accumulate collisions,
// and so the fresh-client assertion cannot pass on a declaration left behind by
// an earlier run. Kept inside the column's 50-char cap (FR-AP-9).
const registrationNumber = `PT-E2E-${Date.now()}`;

// This spec creates its OWN apiary, over REST, before opening the declarations
// screen. That is not incidental setup — the screen groups by registration
// number, and it builds those groups from the org's apiaries plus its existing
// declarations (stock_declarations_screen.dart's `_groups`). With neither, it
// renders only the empty state and there is **no "Record declaration" button to
// click at all**. Depending on some other spec's apiary for that is a trap: the
// suite runs several files concurrently (playwright.config.ts sets
// `fullyParallel: false`, which serializes tests *within* a file, not files
// against each other) and slice.spec.ts deletes its apiary in its own
// `afterAll` — so whether one exists when this file runs is a race, and this
// file's alphabetical position (and therefore its scheduling) just changed with
// its name. Owning the apiary also makes the "no registration number" group
// assertions below meaningful rather than vacuous.
const apiaryName = `E2E declarations ${Date.now()}`;
let createdApiaryId: string | null = null;
let cleanupToken = "";

// Snackbar text, scoped to a <span>.
//
// Flutter web mirrors announcements into a transient
// <flt-announcement-polite aria-live="polite"> node as well as the real
// semantics <span>, so a bare getByText resolves to two elements and trips
// Playwright's strict mode. slice.spec.ts hits the same thing on its
// "Location set:" assertion and solves it the same way.
const snackbar = (page: Page, text: string) =>
  page.locator("span").filter({ hasText: text }).first();

// One recorded declaration in the log, matched on the em dash plus hive count
// and deliberately NOT anchored to the end of the text.
//
// A recorded declaration, located by the GROUP's accessible name.
//
// Two Flutter-web facts stack here, and getting either wrong looks identical
// from the source:
//  1. A declaration card is merged into ONE semantics node, so its accessible
//     name is the whole group's concatenated contents ("PT-… Current hive
//     count: 0 … Sep 2, 2026 — 0 hives 1 apiary"). Nothing's text *ends* with
//     "0 hives", so an anchored /\d+ hives$/ never matches.
//  2. That node has children (the Record/Delete buttons), and Flutter publishes
//     a WITH-CHILDREN node's label as `aria-label`, not DOM text — so
//     `getByText` cannot see it either, however the regex is written. Only a
//     leaf node gets its label as text.
// Both were separate CI failures. `getByRole` matches the accessible name in
// either form, which is why every card-content assertion in this file goes
// through it.
//
// The em dash is what makes the pattern specific to a declaration row: it comes
// from `stockDeclarationSummary` ("{date} — {n} hives"), and the "Current hive
// count: N" line in the same node has no dash. The date is deliberately not
// pinned — it is locale-formatted (LocaleFormatting → intl).
const declarationRow = (page: Page) => page.getByRole("group", { name: /— \d+ hives?/ });

// The group heading shown when apiaries resolve to no registration number at
// all. Asserted ABSENT throughout: this spec's own apiary carries no per-apiary
// A declaration group, located by its ACCESSIBLE NAME rather than by text.
//
// Flutter merges a card into one semantics node, and how it publishes that
// node's label depends on whether the node has children: a LEAF gets the label
// as DOM text, a node WITH children gets it as `aria-label`. A group here always
// contains at least the "Record declaration" button, so its label — which
// carries the registration number — is an attribute, invisible to `getByText`.
// A CI run proved it: the failure snapshot showed
// `group "PT-E2E-… Current hive count: 0 …"` present and correct while
// `getByText("PT-E2E-…")` found nothing. `getByRole` matches on the accessible
// name, so it sees both forms.
const numberGroup = (page: Page, number: string) =>
  // `registrationNumber` is generated as PT-E2E-<digits> (see its declaration),
  // so it holds no regex metacharacters and needs no escaping.
  page.getByRole("group", { name: new RegExp(number) });

// The group a declaration falls into when no registration number is known. The
// apiary this spec creates carries no per-apiary override, so it inherits the
// organization's default — and that default only reaches a client through the
// organization REST read plus its local cache (`organization_repository.dart`;
// the org row is not what the declarations screen groups on). A "No registration
// number" group therefore means that default did not arrive, which is the same
// silent-NULL failure the fresh-client assertion guards against, one field over.
const noNumberGroup = (page: Page) => page.getByRole("group", { name: /No registration number/ });

/**
 * Flutter-web text entry: focus the field, then type real keystrokes.
 *
 * NOT `locator.fill()`. Flutter renders to canvas and only exposes a semantics
 * `<input>` placeholder; the framework's TextEditingController is fed by the
 * engine's text-editing strategy, which listens for key/composition events on
 * whatever element it has made the active editing element. `fill()` sets
 * `input.value` directly and dispatches a single synthetic `input` event before
 * Flutter has finished routing the focus into the widget, so the value never
 * reaches Dart — the field looks filled to Playwright and is empty to the app.
 * That is exactly how this spec's registration-number step used to "pass" its
 * fill, send no PATCH at all, and then fail further down on the
 * "No registration number" group (#298).
 *
 * The Control+A / Delete / Backspace no-op is the same dropped-keystroke
 * settle that slice.spec.ts and registration.spec.ts already use: typing
 * immediately after focus has been observed dropping a variable-length prefix
 * in CI.
 */
async function typeInto(page: Page, field: ReturnType<Page["getByRole"]>, value: string) {
  await field.first().waitFor({ state: "visible", timeout: 30_000 });
  await field.first().click();
  await page.keyboard.press("Control+A");
  await page.keyboard.press("Delete");
  await page.keyboard.press("Backspace");
  await page.keyboard.type(value, { delay: 50 });
}

async function login(page: Page) {
  await submitIdpCredentials(page, TEST_USER, TEST_PASS);
  // After login the app lands on the Home tab (D-35, #658), not the apiaries
  // list. The OIDC callback is a full page load that re-bootstraps Flutter plus
  // the token exchange, so allow generously for a cold stack.
  await page.waitForURL(/\/home/, { timeout: 60_000 });
  await enableSemantics(page);
  await expect(page.getByRole("heading", { name: "Home" })).toBeVisible({ timeout: 30_000 });
}

/**
 * Opens Account from the app shell's header (the account icon button, whose
 * accessible name is its "Account settings" tooltip — app_shell.dart).
 *
 * Only reachable from a shell route; the two screens below are full-screen
 * routes outside the shell, so coming back from them uses [backToAccount].
 */
async function openAccount(page: Page) {
  await page.getByRole("button", { name: "Account settings" }).click();
  await page.waitForURL(/\/account/, { timeout: 30_000 });
  await enableSemantics(page);
  await expect(page.getByRole("heading", { name: "Account settings" })).toBeVisible({
    timeout: 30_000,
  });
}

/**
 * Returns to Account from one of the two screens below, via browser history.
 *
 * `context.go` reports a *navigate* (not a replace), so each entry really is a
 * history entry and Back is a plain popstate — same document, no reload, so the
 * session and the PowerSync connection survive it. Those screens have no in-app
 * back affordance to use instead: reached with `go`, they are the only page on
 * their Navigator, so the AppBar implies no leading button.
 */
async function backToAccount(page: Page) {
  await page.goBack();
  await enableSemantics(page);
  await expect(page.getByRole("heading", { name: "Account settings" })).toBeVisible({
    timeout: 30_000,
  });
}

/**
 * Account → Organization details (#296): the organization's name, address and
 * the beekeeper registration-number default its apiaries inherit.
 *
 * In-app navigation, NOT `page.goto("/organization/details")`. Deep-linking
 * straight to a route does not work, and that is app behaviour worth knowing
 * rather than a test quirk: on a hard page load the session has not been
 * restored yet, so `isAuthenticatedProvider` is briefly false, the router sends
 * /route → /login, and once auth resolves /login → /home (app_router.dart's
 * redirect, D-35/#658). The original destination is dropped. A CI run proved it
 * against the old single screen: waitForURL passed, then the app landed on the
 * post-login tab instead.
 * Flagged on the PR — a bookmark to any in-app route has the same problem,
 * which is not this PR's to fix. The same applies to [openStockDeclarations].
 *
 * The Account entry's label and this screen's title are the same string
 * (`organizationDetailsTitle`), so the role is what tells them apart: the entry
 * is a button, the destination's app-bar title is a heading.
 */
async function openOrganizationDetails(page: Page) {
  await page.getByRole("button", { name: "Organization details" }).click();
  await page.waitForURL(/\/organization\/details/, { timeout: 30_000 });
  await enableSemantics(page);
  await expect(page.getByRole("heading", { name: "Organization details" })).toBeVisible({
    timeout: 30_000,
  });
}

/** Account → Stock declarations (#298). See [openOrganizationDetails] on why this is a click. */
async function openStockDeclarations(page: Page) {
  await page.getByRole("button", { name: "Stock declarations" }).click();
  await page.waitForURL(/\/stock-declarations/, { timeout: 30_000 });
  await enableSemantics(page);
  // The advisory framing is part of the requirement, not decoration (D-19 §7:
  // the app files nothing with any authority). Assert it renders rather than
  // trusting it — and it doubles as "the screen painted", since everything else
  // on it depends on data that still has to arrive.
  await expect(page.getByText(/never files anything for you/)).toBeVisible({ timeout: 30_000 });
}

test("registration number + declaration: recorded here, downloaded by a fresh client", async ({
  page,
  browser,
}) => {
  // Capture a bearer token from the app's own API traffic. The provider
  // disallows the direct grant, so a token is only obtainable from a real
  // authenticated run — same technique as slice.spec.ts. Attached before the
  // login so the first authenticated call (GET /v1/organizations/me) is seen.
  page.on("request", (req) => {
    const auth = req.headers()["authorization"];
    if (auth?.startsWith("Bearer ") && req.url().includes("/v1/")) {
      cleanupToken = auth.slice("Bearer ".length);
    }
  });

  await login(page);
  await expect.poll(() => cleanupToken, { timeout: 30_000 }).not.toBe("");

  // ── This spec's own apiary (see `apiaryName` above for why) ───────────
  // Over REST rather than through the apiary form: the form's mandatory
  // location picker (#341, FR-AP-7) is slice.spec.ts's subject, not this
  // spec's, and driving a canvas map here would only add a way to fail for an
  // unrelated reason. The id is client-supplied (api-contracts.md §4), so
  // teardown knows it without reading the response back. The coordinate is the
  // same mainland-Portugal default the config pins for geolocation.
  createdApiaryId = randomUUID();
  const created = await apiJson(page, cleanupToken, "POST", "/apiaries", {
    id: createdApiaryId,
    name: apiaryName,
    location: { type: "Point", coordinates: [-8.0, 39.5] },
  });
  expect(created.status, `POST /v1/apiaries -> ${JSON.stringify(created.json)}`).toBe(201);

  // ── The organization's registration number (FR-AP-9, #296) ────────────
  // Editing this is an admin-only REST PATCH, not a synced write — the one
  // thing in this flow that needs connectivity (the value is READ offline, from
  // the cached organization). The seeded e2e user is their org's admin (D-3:
  // the creator is the first admin), so the field is enabled and the save
  // button renders at all.
  await openAccount(page);
  await openOrganizationDetails(page);
  const numberField = page.getByRole("textbox", { name: /Registration number/ });
  await expect(numberField).toBeVisible({ timeout: 30_000 });
  await typeInto(page, numberField, registrationNumber);
  // "Save" is MaterialLocalizations' own label, exact so it can't also match a
  // longer button that happens to contain the word.
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(snackbar(page, "Organization details saved")).toBeVisible({ timeout: 30_000 });

  // ── The declaration log, grouped by that number (FR-AP-10, #298) ──────
  await backToAccount(page);
  await openStockDeclarations(page);

  // The group heading is the number itself. Waiting for it here also waits out
  // PowerSync downloading the apiary created above — the group only exists once
  // that row has arrived locally — so the record action below is never clicked
  // against a half-populated screen. 60s for the same reason the fresh-client
  // waits are 60s (see below).
  await expect(numberGroup(page, registrationNumber)).toBeVisible({ timeout: 60_000 });
  await expect(noNumberGroup(page)).toHaveCount(0);

  // One group means one record action, so `.first()` is unambiguous — but
  // assert that rather than assume it: groups are sorted by number and the
  // "no number" group sorts FIRST, so a stray one would silently take this
  // click and file the declaration under the wrong (empty) number, which the
  // fresh-client assertion would then report as a sync failure that isn't one.
  const recordAction = page.getByRole("button", { name: "Record declaration" });
  await expect(recordAction).toHaveCount(1);
  await recordAction.click();
  await enableSemantics(page);

  // The record action opens a dialog rather than writing immediately: a
  // beekeeper files with the authority first and logs it here after, so the
  // date is editable and must not be assumed to be today (FR-AP-10 captures the
  // declaration date, not the record-keeping date). Here we accept the default
  // — the dialog's own date picking is covered by the widget tests — and add
  // the note, which is the other half of what the dialog asks for.
  await expect(page.getByText("Declaration date").first()).toBeVisible({ timeout: 30_000 });
  const noteField = page.getByRole("textbox", { name: /Note \(optional\)/ });
  await expect(noteField).toBeVisible({ timeout: 30_000 });
  await typeInto(page, noteField, "e2e: filed on the authority's portal");
  // Exact: the group's own action behind the modal is "Record declaration", and
  // this dialog's confirm is just "Record".
  await page.getByRole("button", { name: "Record", exact: true }).click();
  await expect(snackbar(page, "Declaration recorded")).toBeVisible({ timeout: 30_000 });

  // The log now shows it.
  await expect(declarationRow(page).first()).toBeVisible({ timeout: 30_000 });

  // ── Nudge the flush, exactly as slice.spec.ts's create step used to ───
  // The connection-quality gate (#55, FR-OF-3) can sit in backoff after a fresh
  // login, so a queued write may not have gone out yet. "Sync now" bypasses the
  // gate and makes the fresh-client assertion below deterministic rather than a
  // race with the backoff. (slice.spec.ts dropped its nudge once #240 made the
  // gate cut a pending backoff short on connectivity-return, because proving
  // *that* is slice's job. It isn't this spec's: here the nudge is a way to
  // stop an unrelated timing property from deciding whether the sync-rules
  // guard below gets to run.)
  await backToAccount(page);
  await page.getByRole("button", { name: "Sync now" }).click();

  // ── A fresh client downloads both (the sync-rules guard) ──────────────
  // THE point of this spec. An empty local SQLite can only show these if
  // PowerSync downloaded them — so this fails loudly if the
  // `apiaries.stock_declarations` bucket entry or the `registration_number`
  // column is missing from the Sync Rules, the one failure mode that is
  // otherwise completely silent.
  //
  // The viewport is passed explicitly: `test.use` above configures the `page`
  // fixture's context, not one opened by hand here, and this client clicks the
  // same two Account entries that need the height (see TALL_VIEWPORT). Every
  // other context option (baseURL, ignoreHTTPSErrors, …) is inherited from
  // playwright.config.ts's `use`, which is why slice.spec.ts's fresh page can
  // `goto("/")` at all — passing one option does not drop the rest.
  //
  // 60s, matching slice.spec.ts: a fresh client's first full-bucket download is
  // gated by the same probe/backoff and legitimately needs more than 30s under
  // CI load.
  const fresh = await browser.newContext({ viewport: TALL_VIEWPORT });
  try {
    const p2 = await fresh.newPage();
    await login(p2);
    await openAccount(p2);

    // The organization details screen, on a client that has never seen this
    // organization. Its registration number is NOT asserted from the field's
    // contents: Flutter's semantic text field (engine
    // semantics/text_field.dart) never writes the field's text into the DOM
    // input outside of active editing — `update()` sets aria-label, enabled
    // state and input type, and nothing else — so `toHaveValue` here reads an
    // empty string no matter what the app is showing. The value's arrival is
    // asserted below instead, where the same number is rendered as real text.
    await openOrganizationDetails(p2);
    await expect(p2.getByRole("textbox", { name: /Registration number/ })).toBeVisible({
      timeout: 60_000,
    });

    await backToAccount(p2);
    await openStockDeclarations(p2);

    // The registration number replicated (FR-AP-9): the group heading renders
    // it as real text, so unlike the field above it can actually be read. The
    // second assertion is what extends this to the ORGANIZATION's copy of the
    // number (the REST read + local cache, not the sync stream): once this
    // client has downloaded the apiary, a default that failed to arrive would
    // put that apiary in its own "No registration number" group next to this
    // one.
    await expect(numberGroup(p2, registrationNumber)).toBeVisible({ timeout: 60_000 });
    await expect(noNumberGroup(p2)).toHaveCount(0);

    // The declaration itself replicated (FR-AP-10) — this is the assertion the
    // sync-rules entry lives or dies by.
    await expect(declarationRow(p2).first()).toBeVisible({ timeout: 60_000 });
  } finally {
    await fresh.close();
  }

  // ── Delete it again: teardown, and the lifecycle a counter lacks ──────
  // Declarations have no REST surface, so this UI delete is the only teardown
  // available — and it covers FR-AP-10's "a mis-entered declaration must be
  // removable", which apiary_counters deliberately does not allow. The first
  // context is still on Account (the "Sync now" above), so this is one hop.
  await openStockDeclarations(page);
  await page.getByRole("button", { name: "Delete declaration" }).first().click();
  // Gone from the log. Asserting the ROW disappears, not that the empty-state
  // text appears: that text lives inside the same merged group node, so a
  // getByText for it would also match the group while a declaration is still
  // present. (And with this spec's apiary still there, the group itself stays.)
  await expect(declarationRow(page)).toHaveCount(0, { timeout: 30_000 });
});

// Test-data teardown (#162) for the apiary this spec created for itself. The
// declaration is deleted through the UI inside the test (it has no REST
// surface); this is the one leftover that does.
//
// Deliberately NOT Playwright's `request` fixture — that issues a plain
// Node-side HTTP request, which doesn't get the browser launch's
// `--host-resolver-rules` (playwright.config.ts's hostMap) that's the whole
// reason the dev hostnames resolve without editing the runner's /etc/hosts. A
// throwaway browser page does inherit it, same as slice.spec.ts's cleanup.
// Best-effort: if the test failed before creating the apiary or capturing a
// token there is nothing to clean up, and a cleanup problem must not turn an
// otherwise-green run red.
test.afterAll(async ({ browser }) => {
  if (!createdApiaryId || !cleanupToken) return;
  const context = await browser.newContext();
  try {
    const page = await context.newPage();
    await page.goto("/");
    const { status } = await apiJson(page, cleanupToken, "DELETE", `/apiaries/${createdApiaryId}`);
    if (status >= 400 && status !== 404) {
      console.warn(`afterAll cleanup: DELETE /v1/apiaries/${createdApiaryId} -> ${status}`);
    }
  } finally {
    await context.close();
  }
});
