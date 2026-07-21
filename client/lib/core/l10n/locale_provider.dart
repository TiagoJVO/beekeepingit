import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/profile/profile_repository.dart';
import '../../l10n/gen/app_localizations.dart';

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
final localeProvider = Provider<Locale?>((ref) {
  final code = ref.watch(profileProvider).value?.locale;
  if (code == null || code.isEmpty) return null;
  for (final supported in AppLocalizations.supportedLocales) {
    if (supported.languageCode == code) return supported;
  }
  return null;
});
