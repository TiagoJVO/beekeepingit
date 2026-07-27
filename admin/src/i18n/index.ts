import i18n from "i18next";
import { initReactI18next } from "react-i18next";
import LanguageDetector from "i18next-browser-languagedetector";
import en from "./locales/en.json";
import pt from "./locales/pt.json";

// EN + PT, strings externalized (NFR-I18N / DoD). Language is auto-detected from the
// browser/localStorage with EN as the fallback; PT is the primary field language.
export const resources = {
  en: { translation: en },
  pt: { translation: pt },
} as const;

export function initI18n(): typeof i18n {
  if (!i18n.isInitialized) {
    void i18n
      .use(LanguageDetector)
      .use(initReactI18next)
      .init({
        resources,
        fallbackLng: "en",
        supportedLngs: ["en", "pt"],
        interpolation: { escapeValue: false },
        detection: {
          order: ["localStorage", "navigator", "htmlTag"],
          caches: ["localStorage"],
        },
      });
  }
  return i18n;
}

export default i18n;
