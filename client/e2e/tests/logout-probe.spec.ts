// TEMPORARY diagnostic spec for #836 — deleted before the fix lands.
//
// v1 established that `logout()` is never entered in the failing attempts, and
// that the browser's main thread is alive at click time. v2 therefore probes
// the CLICK, not the method:
//
//   * does the app-level heartbeat keep ticking after a failed click?
//   * does the Account screen's own `onPressed` marker ever print?
//   * did the semantics node move (Flutter re-laying out under Playwright's
//     scroll-into-view) between resolution and dispatch?
//   * does a retry / force click / DOM dispatchEvent reach the widget?
import { test, expect } from "@playwright/test";
import { enableSemantics, submitIdpCredentials } from "./helpers";

const TEST_USER = process.env.E2E_USER ?? "test.beekeeper@beekeepingit.local";
const TEST_PASS = process.env.E2E_PASS ?? "dev-password123";

const BTN =
  'flt-semantics[aria-label="Sign out"], flt-semantics[role="button"][aria-label="Sign out"]';

// Everything about the Sign out semantics node that could explain a click that
// lands but does nothing: is it in the DOM, where is it, what is on top of its
// own centre point, and how far has its scroll container been scrolled.
const inspect = `() => {
  const el = document.querySelector('${BTN}');
  if (!el) return { present: false };
  const r = el.getBoundingClientRect();
  const cx = Math.round(r.left + r.width / 2);
  const cy = Math.round(r.top + r.height / 2);
  const hit = document.elementFromPoint(cx, cy);
  const scrollers = [...document.querySelectorAll('flt-semantics')]
    .filter((n) => n.scrollTop !== 0 || n.scrollLeft !== 0)
    .map((n) => n.tagName + ':' + n.scrollTop + ',' + n.scrollLeft);
  return {
    present: true,
    connected: el.isConnected,
    rect: [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)],
    centre: [cx, cy],
    hitTag: hit ? hit.tagName : null,
    hitLabel: hit ? hit.getAttribute('aria-label') : null,
    hitIsButtonOrChild: hit ? (hit === el || el.contains(hit) || hit.contains(el)) : false,
    outer: el.outerHTML.slice(0, 300),
    scrollers,
    windowScroll: [window.scrollX, window.scrollY],
  };
}`;

test("PROBE #836 v2: why does the Sign out click not reach the widget?", async ({
  page,
}, testInfo) => {
  const R = `R${testInfo.repeatEachIndex}`;
  const lines: string[] = [];
  const say = (s: string) => {
    // eslint-disable-next-line no-console
    console.log(`${R} ${s}`);
  };
  page.on("console", (msg) => {
    const text = msg.text();
    if (text.includes("[bk836]")) {
      lines.push(text);
      if (!text.includes("HEARTBEAT")) say(text);
    }
  });
  page.on("pageerror", (err) => say(`PAGEERROR ${err.message}`));

  await submitIdpCredentials(page, TEST_USER, TEST_PASS);
  await page.waitForURL(/\/home/, { timeout: 60_000 });
  await enableSemantics(page);
  await expect(page.getByRole("heading", { name: "Home" })).toBeVisible({ timeout: 30_000 });

  await page.getByRole("button", { name: "Account settings" }).click();
  await enableSemantics(page);

  const beats = () => lines.filter((l) => l.includes("HEARTBEAT app")).length;
  const entered = () => lines.some((l) => l.includes("logout:enter"));
  const pressed = () => lines.some((l) => l.includes("account:signOut:onPressed"));

  say(`BEFORE inspect=${JSON.stringify(await page.evaluate(inspect))}`);
  const beatsBefore = beats();

  say(`=== CLICK #1 (plain) ===`);
  await page.getByRole("button", { name: "Sign out" }).click();
  await page.waitForTimeout(3000);
  say(`AFTER#1 url=${page.url()} pressed=${pressed()} entered=${entered()}`);
  say(`AFTER#1 inspect=${JSON.stringify(await page.evaluate(inspect))}`);
  // A JS round trip AFTER the click: if this answers, the main thread is alive.
  say(`AFTER#1 evaluate=${await page.evaluate(() => 21 * 2)} beatsDelta=${beats() - beatsBefore}`);

  if (!pressed()) {
    say(`=== CLICK #2 (plain retry) ===`);
    await page.getByRole("button", { name: "Sign out" }).click();
    await page.waitForTimeout(3000);
    say(`AFTER#2 url=${page.url()} pressed=${pressed()}`);
  }

  if (!pressed()) {
    say(`=== CLICK #3 (force, no actionability/scroll) ===`);
    await page.getByRole("button", { name: "Sign out" }).click({ force: true });
    await page.waitForTimeout(3000);
    say(`AFTER#3 url=${page.url()} pressed=${pressed()}`);
  }

  if (!pressed()) {
    say(`=== CLICK #4 (DOM dispatchEvent on the semantics node) ===`);
    await page.evaluate(`() => {
      const el = document.querySelector('${BTN}');
      el && el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
    }`);
    await page.waitForTimeout(3000);
    say(`AFTER#4 url=${page.url()} pressed=${pressed()}`);
  }

  if (!pressed()) {
    say(`=== CLICK #5 (el.click()) ===`);
    await page.evaluate(`() => { const el = document.querySelector('${BTN}'); el && el.click(); }`);
    await page.waitForTimeout(3000);
    say(`AFTER#5 url=${page.url()} pressed=${pressed()}`);
  }

  say(
    `SUMMARY pressed=${pressed()} entered=${entered()} url=${page.url()} ` +
      `heartbeats=${beats()} (delta since before click ${beats() - beatsBefore})`,
  );
});
