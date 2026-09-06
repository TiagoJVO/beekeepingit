import i18n from "i18next";
import { DEFAULT_LOCALE, normalizeLocale, type SupportedLocale } from "./supportedLocales";

/**
 * Locale-aware date and number formatting for the admin app (NFR-I18N-1, D-34).
 *
 * **No screen formats a date or a grouped number today** — the org, member and
 * role screens render plain strings and ICU-pluralized counts only. This module
 * exists so the *first* one that does goes through the resolved locale instead
 * of reaching for `toLocaleDateString()` with no argument (which follows the
 * host's locale, not the app's) or `Intl` with a hand-written tag. It is
 * deliberately thin: the counterpart of the client's `LocaleFormatting`
 * (`client/lib/core/l10n/locale_formatting.dart`, #656), so the two apps cannot
 * disagree about how a date is written.
 *
 * Call these from a component that also uses `useTranslation()` — that is what
 * re-renders the subtree when the language changes.
 */

/**
 * The locale the app actually resolved, always country-qualified.
 *
 * i18next would already have fallen back for an unsupported language, but this
 * also collapses a generic `en`/`pt` to `en-GB`/`pt-PT`: formatting against the
 * bare code is exactly the American/Brazilian-conventions bug D-34 removes.
 */
export function resolvedLocale(): SupportedLocale {
  return normalizeLocale(i18n.resolvedLanguage ?? i18n.language) ?? DEFAULT_LOCALE;
}

/**
 * The only `Intl.DateTimeFormat` option a caller may set: which fields are
 * rendered is {@link formatDate}'s contract (D-34's pinned pattern), not the
 * caller's. `timeZone` is orthogonal to that and is what a test — or a screen
 * rendering a stored UTC timestamp — legitimately needs.
 */
export type DateFormatOptions = Pick<Intl.DateTimeFormatOptions, "timeZone">;

/**
 * A date with a named month, day first: `3 Sept 2026` (en-GB) / `3 set. 2026`
 * (pt-PT).
 *
 * **This deliberately overrides CLDR's own medium date** (D-34) — the one place
 * the app departs from the active locale's defaults. CLDR's `yMMMd` for `pt-PT`
 * is the wholly numeric `d/MM/y` → `3/09/2026`, and a numeric date is the one
 * form a reader can genuinely get wrong (`3/09` and `09/03` are the same
 * characters reordered) while a named month cannot be misread. Only the pattern
 * is pinned, never the symbols: the month name stays fully localized, including
 * European Portuguese's trailing dot.
 *
 * `Intl` has no pattern argument, so the pattern is imposed by formatting each
 * field on its own and joining them — asking for `month: "short"` alongside the
 * day and year gets you CLDR's `yMMMd`, numeric month and all.
 *
 * That is also why [options] is deliberately narrowed to `timeZone` rather than
 * the whole `Intl.DateTimeFormatOptions` surface: any field option would be
 * repeated once per segment (`hour` would render `3, 15:04 Sept, 15:04 2026,
 * 15:04`). Which fields appear is this function's contract, not the caller's.
 */
export function formatDate(
  value: Date,
  locale: SupportedLocale = resolvedLocale(),
  options: DateFormatOptions = {},
): string {
  const field = (field: Intl.DateTimeFormatOptions) =>
    new Intl.DateTimeFormat(locale, { ...options, ...field }).format(value);
  return `${field({ day: "numeric" })} ${field({ month: "short" })} ${field({ year: "numeric" })}`;
}

/**
 * {@link formatDate} plus a 24-hour time — `3 Sept 2026 15:04` — so a date and
 * a date-with-time can never disagree about how the month is written. Both
 * locales use a 24-hour clock rather than switching to AM/PM.
 */
export function formatDateTime(
  value: Date,
  locale: SupportedLocale = resolvedLocale(),
  options: DateFormatOptions = {},
): string {
  const time = new Intl.DateTimeFormat(locale, {
    ...options,
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(value);
  return `${formatDate(value, locale, options)} ${time}`;
}

/**
 * A number with the locale's grouping and decimal separators: `1,234,567.5`
 * (en-GB) / `1 234 567,5` (pt-PT, grouped with a non-breaking space — D-34).
 *
 * Use this, not `String(value)`, for any number read from stored data.
 */
export function formatNumber(
  value: number,
  locale: SupportedLocale = resolvedLocale(),
  options: Intl.NumberFormatOptions = {},
): string {
  return new Intl.NumberFormat(locale, options).format(value);
}
