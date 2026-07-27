import 'package:flutter/material.dart';

import '../theming/brand_widgets.dart';

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
    return EmptyState(message: title, icon: icon);
  }
}
