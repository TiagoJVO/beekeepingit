import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';

/// The shared apiary search-field [InputDecoration] (#762, D-17) — the
/// `hintText`/`Icons.search`/`isDense: true` triplet FOUR search fields
/// built inline: `todo_apiary_picker_field.dart`'s and
/// `apiary_multi_select_field.dart`'s own pickers,
/// `new_activity_flow_screen.dart`'s `_ApiaryStep`, and
/// `apiaries_list_screen.dart`'s own top-level search field.
///
/// Lives beside [filterApiariesByQuery] (`apiaries_repository.dart`) rather
/// than `core/widgets/` — like that function, it is apiary-search-specific
/// (the fixed `l10n.apiariesSearchHint` copy), not a general-purpose,
/// feature-agnostic primitive.
///
/// [suffixIcon] is the one place the four copies genuinely differed:
/// `apiaries_list_screen.dart` shows a conditional clear button (its own
/// search query is a persisted provider that can be non-empty across
/// rebuilds) while the other three never did. Passing it through as an
/// optional parameter, rather than hard-coding a clear button here, keeps
/// the other three call sites' behaviour byte-identical.
InputDecoration apiarySearchDecoration(
  AppLocalizations l10n, {
  Widget? suffixIcon,
}) {
  return InputDecoration(
    hintText: l10n.apiariesSearchHint,
    prefixIcon: const Icon(Icons.search),
    isDense: true,
    suffixIcon: suffixIcon,
  );
}
