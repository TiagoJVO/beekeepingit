import { afterEach, describe, expect, it } from "vitest";
import { createInstance } from "i18next";
import LanguageDetector from "i18next-browser-languagedetector";
import i18n, { createI18nOptions, initI18n, resources } from "./index";
import { DEFAULT_LOCALE, SUPPORTED_LOCALES } from "./supportedLocales";

// The key `i18next-browser-languagedetector` caches the detected language under.
const CACHE_KEY = "i18nextLng";

/**
 * Boots a throwaway i18next instance with the app's real options, so a test can
 * pin what a given browser/cache state resolves to without disturbing the shared
 * singleton the rest of the suite renders through.
 */
async function resolve(state: { navigator?: string[]; cached?: string }) {
  window.localStorage.removeItem(CACHE_KEY);
  if (state.cached !== undefined) {
    window.localStorage.setItem(CACHE_KEY, state.cached);
  }
  const languages = state.navigator ?? [];
  Object.defineProperty(window.navigator, "languages", {
    value: languages,
    configurable: true,
  });
  Object.defineProperty(window.navigator, "language", {
    value: languages[0],
    configurable: true,
  });

  const instance = createInstance();
  await instance.use(LanguageDetector).init(createI18nOptions());
  return instance;
}

afterEach(() => {
  window.localStorage.removeItem(CACHE_KEY);
});

describe("admin i18n configuration (D-34)", () => {
  it("keys its bundles by the region-qualified locales the product ships", () => {
    expect(Object.keys(resources)).toEqual(["en-GB", "pt-PT"]);
    const options = createI18nOptions();
    expect(options.supportedLngs).toEqual([...SUPPORTED_LOCALES]);
    expect(options.fallbackLng).toBe(DEFAULT_LOCALE);
  });

  it("initializes the shared instance on a supported locale", () => {
    const instance = initI18n();
    expect(instance.isInitialized).toBe(true);
    expect(SUPPORTED_LOCALES).toContain(instance.resolvedLanguage);
  });
});

describe("language resolution from the browser", () => {
  it.each([
    ["en-GB", "en-GB"],
    ["en-US", "en-GB"],
    ["pt-PT", "pt-PT"],
    ["pt-BR", "pt-PT"],
  ])("resolves a browser reporting %s to the %s bundle", async (reported, expected) => {
    const instance = await resolve({ navigator: [reported] });

    expect(instance.resolvedLanguage).toBe(expected);
    expect(instance.t("app.title")).toBe(
      resources[expected as keyof typeof resources].translation.app.title,
    );
  });

  it("falls back to British English when the browser reports nothing usable", async () => {
    const instance = await resolve({ navigator: ["fr-FR"] });

    expect(instance.resolvedLanguage).toBe(DEFAULT_LOCALE);
    expect(instance.t("app.title")).toBe("BeekeepingIT Admin");
  });
});

describe("a language cached before the D-34 rename", () => {
  it.each([
    ["en", "en-GB"],
    ["pt", "pt-PT"],
  ])("migrates a cached %s to %s instead of leaving a missing bundle", async (cached, expected) => {
    // The browser says the opposite language, so a pass-through of the cached
    // value is the only thing that can produce `expected` here.
    const other = expected === "en-GB" ? "pt-PT" : "en-GB";
    const instance = await resolve({ cached, navigator: [other] });

    expect(instance.resolvedLanguage).toBe(expected);
    expect(instance.t("app.title")).toBe(
      resources[expected as keyof typeof resources].translation.app.title,
    );
    // ...and the cache is rewritten canonically, so the migration happens once.
    expect(window.localStorage.getItem(CACHE_KEY)).toBe(expected);
  });

  it("ignores a cached language the app does not ship and uses the browser's", async () => {
    const instance = await resolve({ cached: "fr", navigator: ["pt-BR"] });

    expect(instance.resolvedLanguage).toBe("pt-PT");
  });
});

describe("the document language", () => {
  afterEach(async () => {
    await i18n.changeLanguage(DEFAULT_LOCALE);
  });

  it("follows the resolved locale so assistive tech reads the right language (WCAG 3.1.1)", async () => {
    await i18n.changeLanguage("pt-PT");
    expect(document.documentElement.lang).toBe("pt-PT");

    await i18n.changeLanguage("en-GB");
    expect(document.documentElement.lang).toBe("en-GB");
  });
});
