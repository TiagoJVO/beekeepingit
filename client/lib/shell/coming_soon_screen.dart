import 'package:flutter/material.dart';

/// Minimal, honest placeholder for a bottom-nav tab whose real screens
/// haven't landed yet (Activities = M3, Journeys = M4, Todos = M5,
/// Assistant = M8 — see docs/design/prototype.md's feature→backlog map).
/// Deliberately doesn't fake list/detail chrome: just says what's missing
/// and when it's coming, so nobody mistakes it for a broken real screen.
class ComingSoonScreen extends StatelessWidget {
  const ComingSoonScreen({required this.icon, required this.title, super.key});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}
