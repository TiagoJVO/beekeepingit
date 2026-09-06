import { describe, expect, it } from "vitest";
import { DEFAULT_LOCALE, SUPPORTED_LOCALES, normalizeLocale } from "./supportedLocales";

describe("supported locales (D-34)", () => {
  it("ships exactly British English and European Portuguese", () => {
    expect(SUPPORTED_LOCALES).toEqual(["en-GB", "pt-PT"]);
  });

  it("defaults to the head of the supported list", () => {
    expect(DEFAULT_LOCALE).toBe("en-GB");
    expect(SUPPORTED_LOCALES[0]).toBe(DEFAULT_LOCALE);
  });

  it.each([
    ["en-GB", "en-GB"],
    ["pt-PT", "pt-PT"],
    // Bare codes: what a browser — or a localStorage cache written before this
    // change — reports. They must not strand a user on a missing bundle.
    ["en", "en-GB"],
    ["pt", "pt-PT"],
    // A supported language in a region we do not ship maps to the one we do.
    ["en-US", "en-GB"],
    ["pt-BR", "pt-PT"],
    // Separator / case / extra-subtag variants are canonicalized, not rejected.
    ["pt_PT", "pt-PT"],
    ["EN-gb", "en-GB"],
    ["en-Latn-US", "en-GB"],
    ["  pt-br  ", "pt-PT"],
  ])("normalizes %s to %s", (raw, expected) => {
    expect(normalizeLocale(raw)).toBe(expected);
  });

  it.each([["fr"], ["fr-FR"], ["xx"], [""], ["   "], [null], [undefined]])(
    "returns null for %s, a language the app does not ship",
    (raw) => {
      expect(normalizeLocale(raw)).toBeNull();
    },
  );
});
