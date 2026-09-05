import { afterEach, describe, expect, it } from "vitest";
import i18n from "./index";
import { DEFAULT_LOCALE } from "./supportedLocales";
import { formatDate, formatDateTime, formatNumber, resolvedLocale } from "./formatting";

// A fixed instant, in UTC, so the assertions do not depend on the runner's zone.
const instant = new Date(Date.UTC(2026, 8, 3, 15, 4));
const utc = { timeZone: "UTC" };

describe("resolvedLocale", () => {
  afterEach(async () => {
    await i18n.changeLanguage(DEFAULT_LOCALE);
  });

  it("reads the locale i18next actually resolved", async () => {
    await i18n.changeLanguage("pt-PT");
    expect(resolvedLocale()).toBe("pt-PT");

    await i18n.changeLanguage("en-GB");
    expect(resolvedLocale()).toBe("en-GB");
  });

  it("never hands back an unsupported locale", async () => {
    // i18next itself would fall back, but a caller must never format against a
    // generic `en`/`pt` — that is the American/Brazilian convention D-34 removes.
    await i18n.changeLanguage("en");
    expect(resolvedLocale()).toBe("en-GB");
  });
});

describe("formatNumber", () => {
  it("uses British grouping and decimal separators for en-GB", () => {
    expect(formatNumber(1234567.5, "en-GB")).toBe("1,234,567.5");
    expect(formatNumber(62.5, "en-GB")).toBe("62.5");
  });

  it("uses European Portuguese separators for pt-PT (D-34: a non-breaking space groups)", () => {
    expect(formatNumber(1234567.5, "pt-PT")).toBe("1 234 567,5");
    expect(formatNumber(62.5, "pt-PT")).toBe("62,5");
  });

  it("defaults to the resolved locale", () => {
    expect(formatNumber(1234567.5)).toBe(formatNumber(1234567.5, resolvedLocale()));
  });
});

describe("formatDate", () => {
  it("names the month in both locales, day first (D-34's pinned pattern)", () => {
    expect(formatDate(instant, "en-GB", utc)).toBe("3 Sept 2026");
    expect(formatDate(instant, "pt-PT", utc)).toBe("3 set. 2026");
  });

  it("never renders the wholly numeric date CLDR would pick for pt-PT", () => {
    // CLDR's medium date for pt-PT is `d/MM/y` → `3/09/2026`, which a reader can
    // misread as 9 March. D-34 pins a named month instead.
    expect(formatDate(instant, "pt-PT", utc)).not.toContain("/");
  });

  it("defaults to the resolved locale", () => {
    expect(formatDate(instant)).toBe(formatDate(instant, resolvedLocale()));
  });

  it("honours the time zone, the one option a caller may set", () => {
    // Which FIELDS are rendered is the function's contract (D-34's pinned
    // pattern) — a caller that could pass `hour` here would get it repeated
    // once per field. `timeZone` is orthogonal, so it is the whole option type.
    expect(formatDate(instant, "en-GB", { timeZone: "UTC" })).toBe("3 Sept 2026");
    expect(formatDate(instant, "en-GB", { timeZone: "Pacific/Auckland" })).toBe("4 Sept 2026");
  });
});

describe("formatDateTime", () => {
  it("adds a 24-hour time to the same pinned date", () => {
    expect(formatDateTime(instant, "en-GB", utc)).toBe("3 Sept 2026 15:04");
    expect(formatDateTime(instant, "pt-PT", utc)).toBe("3 set. 2026 15:04");
  });
});
