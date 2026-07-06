import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/gateway_status.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../routing/app_router.dart';

const sampleApiaryId = 'sample-apiary';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final gatewayStatus = ref.watch(gatewayReachabilityProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.homeTitle)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              l10n.homeSubtitle,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 24),
            _GatewayStatusRow(l10n: l10n, status: gatewayStatus),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => context.goNamed(
                apiaryDetailRouteName,
                pathParameters: const {'id': sampleApiaryId},
              ),
              child: Text(l10n.homeOpenSampleApiaryButton),
            ),
          ],
        ),
      ),
    );
  }
}

class _GatewayStatusRow extends StatelessWidget {
  const _GatewayStatusRow({required this.l10n, required this.status});

  final AppLocalizations l10n;
  final AsyncValue<GatewayReachability> status;

  @override
  Widget build(BuildContext context) {
    return status.when(
      data: (value) => _row(reachable: value == GatewayReachability.reachable),
      error: (_, __) => _row(reachable: false),
      loading: () => Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text('${l10n.gatewayStatusLabel}: ${l10n.gatewayStatusChecking}'),
        ],
      ),
    );
  }

  Widget _row({required bool reachable}) {
    return Row(
      children: [
        Icon(
          reachable ? Icons.check_circle : Icons.error,
          color: reachable ? Colors.green : Colors.red,
        ),
        const SizedBox(width: 8),
        Text(
          '${l10n.gatewayStatusLabel}: '
          '${reachable ? l10n.gatewayStatusReachable : l10n.gatewayStatusUnreachable}',
        ),
      ],
    );
  }
}
