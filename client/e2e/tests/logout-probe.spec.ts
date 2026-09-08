// TEMPORARY diagnostic spec for #836 — deleted before the fix lands.
//
// The decisive experiment: click Sign out, then watch the browser console for
// the `[bk836]` heartbeat the app arms at the top of `logout()`.
//
//   heartbeat STOPS  -> the browser main thread is wedged (a Dart Timer on web
//                       is a setTimeout, so no timers means no event loop)
//   heartbeat TICKS  -> the thread is alive and something is awaiting forever
//
// The MICROTASK probe discriminates further: timers dead + microtasks alive is
// microtask starvation, not a wedge.
import { test, expect } from "@playwright/test";
import { enableSemantics, submitIdpCredentials } from "./helpers";

const TEST_USER = process.env.E2E_USER ?? "test.beekeeper@beekeepingit.local";
const TEST_PASS = process.env.E2E_PASS ?? "dev-password123";

test("PROBE #836: does the main thread survive Sign out?", async ({ page }, testInfo) => {
  const lines: string[] = [];
  page.on("console", (msg) => {
    const text = msg.text();
    if (text.includes("[bk836]")) {
      lines.push(`${Date.now()} ${text}`);
      // eslint-disable-next-line no-console
      console.log(`R${testInfo.repeatEachIndex} ${text}`);
    }
  });
  page.on("pageerror", (err) => {
    // eslint-disable-next-line no-console
    console.log(`R${testInfo.repeatEachIndex} PAGEERROR ${err.message}`);
  });

  await submitIdpCredentials(page, TEST_USER, TEST_PASS);
  await page.waitForURL(/\/home/, { timeout: 60_000 });
  await enableSemantics(page);
  await expect(page.getByRole("heading", { name: "Home" })).toBeVisible({ timeout: 30_000 });

  await page.getByRole("button", { name: "Account settings" }).click();
  await enableSemantics(page);

  // eslint-disable-next-line no-console
  console.log(`R${testInfo.repeatEachIndex} === CLICKING SIGN OUT at ${Date.now()} ===`);
  await page.getByRole("button", { name: "Sign out" }).click();

  // Poll for 45s. Deliberately does NOT use waitForURL — a wedged page cannot
  // serve waitForURL's lifecycle wait, which is exactly what this probe is
  // trying to observe rather than trip over. `page.url()` is answered by the
  // driver, not by page JS, so it keeps working on a wedged page.
  const start = Date.now();
  for (let i = 0; i < 45; i++) {
    await new Promise((r) => setTimeout(r, 1000));
    // eslint-disable-next-line no-console
    console.log(
      `R${testInfo.repeatEachIndex} POLL t=${Date.now() - start}ms url=${page.url()} bk836Lines=${lines.length}`,
    );
  }

  // eslint-disable-next-line no-console
  console.log(
    `R${testInfo.repeatEachIndex} === PROBE SUMMARY ===\n${lines.join("\n")}\n=== END (${lines.length} lines) ===`,
  );
});
