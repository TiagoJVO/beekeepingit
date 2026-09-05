import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/profile/profile_repository.dart';
import 'supported_locales.dart';

/// The app's active UI locale (NFR-I18N-1, FR-ST-1, #340).
///
/// Derived from the caller's stored profile `locale` (the value written by
/// the Account screen's `account-locale-field`) so a language change takes
/// effect **app-wide the instant the profile state updates** — no restart.
/// `app.dart` feeds this into `MaterialApp.router(locale: ...)`; the whole
/// widget tree re-localizes reactively because the provider is watched there.
///
/// Returns `null` when there is no usable stored preference — before login,
/// while the profile is still loading, offline before the first successful
/// fetch, or when the stored code isn't a supported locale — so
/// `MaterialApp` falls back to the device/system locale exactly as it did
/// before this provider existed.
///
/// Persistence across restarts and offline behaviour are inherent, not
/// bolted on here: the choice lives on the server-side profile and is
/// re-read into `profileProvider` on next launch, and once loaded the
/// selection is applied purely client-side (no network needed to
/// re-localize).
/// Resolution goes through [supportedLocaleFor], not a `languageCode ==`
/// comparison (#656/D-34): matching on the language alone could not tell
/// `pt-PT` from `pt-BR` or `en-GB` from `en-US`, and a profile stored before
/// #656 holds the bare `pt`/`en` — which must land on the country variant we
/// ship, not on the device locale and not on Brazilian/American conventions.
final localeProvider = Provider<Locale?>((ref) {
  return supportedLocaleFor(ref.watch(profileProvider).value?.locale);
});
