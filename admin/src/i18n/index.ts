import i18n, { type InitOptions } from "i18next";
import { initReactI18next } from "react-i18next";
import LanguageDetector from "i18next-browser-languagedetector";
import enGB from "./locales/en-GB.json";
import ptPT from "./locales/pt-PT.json";
import { DEFAULT_LOCALE, SUPPORTED_LOCALES, normalizeLocale } from "./supportedLocales";

// British English + European Portuguese, strings externalized (NFR-I18N-1, D-34 / DoD).
// The bundles are keyed by the FULL locale tag — see supportedLocales.ts for why the
// country code is the decision and not a detail. Language is auto-detected from
// localStorage/the browser, with British English as the fallback.
export const resources = {
  "en-GB": { translation: enGB },
  "pt-PT": { translation: ptPT },
} as const;

/**
 * The app's i18next options, built fresh per call — `init()` takes ownership of
 * what it is handed (it appends `cimode` to `supportedLngs`, among other
 * things), so a shared object would leak between the app and any test instance.
 *
 * Exported so a test can boot a throwaway instance with the app's real options
 * and pin what a given browser/cache state resolves to.
 */
export const createI18nOptions = (): InitOptions => ({
  resources,
  fallbackLng: DEFAULT_LOCALE,
  supportedLngs: [...SUPPORTED_LOCALES],
  // Only ever load the tag we resolved. The default ("languageOnly" fallbacks)
  // would have i18next also look for a generic `en`/`pt` bundle, which is
  // precisely the pair of identifiers D-34 removes from the app.
  load: "currentOnly",
  interpolation: { escapeValue: false },
  detection: {
    order: ["localStorage", "navigator", "htmlTag"],
    caches: ["localStorage"],
    // Every detected value — including the one cached in localStorage before
    // this change, and a browser reporting `en-US`/`pt-BR` — is mapped onto a
    // locale we ship, so nobody is left on a bundle that does not exist. An
    // unsupported language is passed through UNCHANGED rather than coerced:
    // `supportedLngs` then drops it and the next detector (or the fallback)
    // gets its turn, which is the honest answer for a language we do not ship.
    convertDetectedLanguage: (lng: string) => normalizeLocale(lng) ?? lng,
  },
});

/**
 * Keeps `<html lang>` in step with the resolved locale, so assistive tech
 * announces the page in the language it is actually written in (WCAG 3.1.1,
 * NFR-I18N-1) instead of the build-time default in index.html.
 */
function syncDocumentLanguage(language: string): void {
  // The app only ever runs in a browser, but `initI18n()` is also called from
  // the test setup, which some suites run in a DOM-less node environment.
  if (typeof document === "undefined") return;
  document.documentElement.lang = normalizeLocale(language) ?? DEFAULT_LOCALE;
}

export function initI18n(): typeof i18n {
  if (!i18n.isInitialized) {
    void i18n.use(LanguageDetector).use(initReactI18next).init(createI18nOptions());
    i18n.on("languageChanged", syncDocumentLanguage);
    syncDocumentLanguage(i18n.resolvedLanguage ?? DEFAULT_LOCALE);
  }
  return i18n;
}

export default i18n;
