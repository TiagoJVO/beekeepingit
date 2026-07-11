import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_controller.dart';
import '../../l10n/gen/app_localizations.dart';
import '../organization/organization_repository.dart';
import 'apiaries_repository.dart';

/// The home screen: the org's apiaries, read live from local SQLite (works
/// offline). Tapping a row opens the edit form; the FAB creates a new one.
class ApiariesListScreen extends ConsumerWidget {
  const ApiariesListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final apiaries = ref.watch(apiariesStreamProvider);
    final isOrgAdmin = ref.watch(isOrgAdminProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.apiariesTitle),
        actions: [
          // Admin-only (#172): the destination screen's endpoints are
          // admin-only server-side (auth.md §5.3), so a non-admin would only
          // hit a dead-end 403 — hide the entry point rather than show one
          // that never works.
          if (isOrgAdmin)
            IconButton(
              key: const Key('manage-members-button'),
              tooltip: l10n.manageMembers,
              icon: const Icon(Icons.group_outlined),
              onPressed: () => context.go('/organization/members'),
            ),
          IconButton(
            key: const Key('account-settings-button'),
            tooltip: l10n.accountTitle,
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () => context.go('/account'),
          ),
          IconButton(
            key: const Key('logout-button'),
            tooltip: l10n.logout,
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(authControllerProvider.notifier).logout(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add-apiary-fab'),
        onPressed: () => context.go('/apiaries/new'),
        icon: const Icon(Icons.add),
        label: Text(l10n.addApiary),
      ),
      body: apiaries.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(l10n.apiariesError('$err')),
          ),
        ),
        data: (list) {
          if (list.isEmpty) {
            return Center(child: Text(l10n.apiariesEmpty));
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final apiary = list[i];
              return ListTile(
                key: Key('apiary-${apiary.id}'),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                title: Text(apiary.name),
                subtitle: Text(l10n.hiveCountValue(apiary.hiveCount)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go('/apiaries/${apiary.id}'),
              );
            },
          );
        },
      ),
    );
  }
}
