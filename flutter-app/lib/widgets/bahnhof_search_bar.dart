import 'package:flutter/material.dart';

import 'glass_panel.dart';

/// The one search-bar shell the three Bahnhof views share (Zug / Abfahrten /
/// Karte), so switching between them never changes the search's size or frame.
///
/// A [GlassPanel] holding a borderless, dense field — pass a
/// `StationSearchField(dense: true, bare: true)` or an equivalently-bare
/// [TextField]. Optional [trailing] widgets (a refresh button, a mode toggle)
/// sit inside the same bar to the right.
class BahnhofSearchBar extends StatelessWidget {
  final Widget child;
  final List<Widget> trailing;

  const BahnhofSearchBar({
    super.key,
    required this.child,
    this.trailing = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: GlassPanel(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            children: [
              Expanded(child: child),
              ...trailing,
            ],
          ),
        ),
      ),
    );
  }
}
