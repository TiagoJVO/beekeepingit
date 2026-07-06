import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';

/// Placeholder detail route (AC of #21). Reads a real apiary once the
/// walking-skeleton slice (#23) lands the `apiaries` service + local store.
class ApiaryDetailScreen extends StatelessWidget {
  const ApiaryDetailScreen({required this.apiaryId, super.key});

  final String apiaryId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.apiaryDetailTitle)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(l10n.apiaryDetailBody(apiaryId)),
      ),
    );
  }
}
