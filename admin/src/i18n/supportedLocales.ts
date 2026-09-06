/**
 * The locales the admin app ships, and the one place a raw locale code is
 * turned into one of them (D-34, NFR-I18N-1, C-2; #659 — mirrors the client's
 * `client/lib/core/l10n/supported_locales.dart` from #656).
 *
 * **Why the country code is load-bearing.** `en` and `pt` are not neutral
 * identifiers: CLDR — which is what `Intl` resolves against — reads them as
 * *American* and *Brazilian*. An app that says `en`/`pt` therefore renders
 * `Sep 3, 2026` to a British reader and `1.234,5` to a Portuguese one: the
 * wrong conventions for both of its audiences. D-34 settles the supported set
 * as British English and European Portuguese, so every locale identifier here
 * is country-qualified.
 */
export const SUPPORTED_LOCALES = ["en-GB", "pt-PT"] as const;

export type SupportedLocale = (typeof SUPPORTED_LOCALES)[number];

/**
 * The locale a caller gets when nothing is stored and nothing is resolvable —
 * the head of {@link SUPPORTED_LOCALES}, matching i18next's own "fall back to
 * the first supported language" rule.
 */
export const DEFAULT_LOCALE: SupportedLocale = SUPPORTED_LOCALES[0];

/**
 * The supported locale `raw` means, or `null` if it means none of them.
 *
 * This is the whole of #659's migration story, and it runs on every read rather
 * than as a one-shot rewrite, so it also holds for a value written by an older
 * build of the app:
 *
 * - `en-GB` / `pt-PT` — already canonical.
 * - `en` / `pt` — what `localStorage` holds for anyone who used the admin app
 *   before this change, and what a browser may still report. Mapped to the
 *   country variant of the same language, so an existing user keeps the
 *   language they had and gains the right conventions instead of landing on a
 *   bundle that no longer exists.
 * - `en-US` / `pt-BR` — a supported *language* in a region we do not ship maps
 *   to the region we do. Portugal is the only in-scope market (C-2), and
 *   answering "Portuguese" with European Portuguese beats not matching at all.
 * - `pt_PT`, `EN-gb`, `en-Latn-US` — separator, case and extra-subtag variants
 *   are canonicalized rather than rejected.
 * - anything else (`fr`, `xx`, blank) — `null`. The caller then falls through
 *   to the next detector or to {@link DEFAULT_LOCALE}; it is never stored or
 *   offered as a choice.
 */
export function normalizeLocale(raw: string | null | undefined): SupportedLocale | null {
  const language = raw?.trim().replace(/_/g, "-").split("-")[0]?.toLowerCase();
  if (!language) return null;
  return SUPPORTED_LOCALES.find((locale) => locale.split("-")[0] === language) ?? null;
}
