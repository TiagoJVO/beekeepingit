import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/field_action_button.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/brand_widgets.dart';
import '../todos/todos_repository.dart';
import 'apiaries_repository.dart';

/// The quick-glance apiary sheet opened by tapping a map pin while the
/// tap-to-measure ruler is OFF (#388): a plain tap on a pin used to feed the
/// always-on measure selection, leaving "open the apiary" reachable only via
/// a non-discoverable long-press. With the ruler off by default, a tap now
/// opens this small modal instead — apiary name, its open-todo count (live,
/// offline-first, via [openTodoCountForApiaryProvider]), and a "View apiary"
/// action that navigates to the same detail route the long-press handler
/// already uses.
///
/// Mirrors journey_quick_create_sheet.dart's `showModalBottomSheet` shape,
/// but dismissible/draggable (unlike that form sheet) — this is a read-mostly
/// glance, not a multi-field form a user could lose work from by dismissing
/// accidentally.
Future<void> showApiaryMapInfoSheet(
  BuildContext context, {
  required Apiary apiary,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isDismissible: true,
    enableDrag: true,
    builder: (_) => _ApiaryMapInfoSheet(apiary: apiary),
  );
}

class _ApiaryMapInfoSheet extends ConsumerWidget {
  const _ApiaryMapInfoSheet({required this.apiary});

  final Apiary apiary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final openTodosAsync = ref.watch(openTodoCountForApiaryProvider(apiary.id));
    // Loading/error both render gracefully (this provider's own doc comment
    // — never crash the sheet over a still-resolving or errored count): an
    // ellipsis while the derivation is still catching up, zero on error
    // rather than surfacing the underlying exception in a glance sheet.
    final openTodosText = switch (openTodosAsync) {
      AsyncData(:final value) => l10n.apiaryMapInfoOpenTodos(value),
      AsyncError() => l10n.apiaryMapInfoOpenTodos(0),
      _ => '…',
    };

    return SafeArea(
      child: Padding(
        key: const Key('apiary-map-info-sheet'),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(apiary.name),
            const SizedBox(height: 8),
            Text(openTodosText, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 20),
            PrimaryActionButton(
              key: const Key('apiary-map-info-view-button'),
              label: l10n.apiaryMapInfoViewApiary,
              onPressed: () {
                Navigator.of(context).pop();
                context.go('/apiaries/${apiary.id}');
              },
            ),
          ],
        ),
      ),
    );
  }
}
