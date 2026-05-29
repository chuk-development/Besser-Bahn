import 'package:flutter/material.dart';

/// Mounts [builder]'s widget only once it scrolls into (near) the enclosing
/// scroll viewport, showing [placeholder] until then. Once mounted it stays
/// mounted, so scrolling away and back does not rebuild it.
///
/// This stops expensive, network-heavy children (e.g. a `flutter_map` with its
/// tile requests) from loading while they're off-screen — the maps for the
/// later legs of a connection no longer hammer the tile server before the user
/// has scrolled down to them.
///
/// Dependency-free: it listens to the nearest [Scrollable]'s position and
/// re-checks its own render box against the viewport rect.
class LazyMount extends StatefulWidget {
  final WidgetBuilder builder;
  final Widget placeholder;

  /// How far outside the viewport (px) still counts as "visible", so the child
  /// is ready by the time it's actually scrolled in.
  final double margin;

  const LazyMount({
    super.key,
    required this.builder,
    required this.placeholder,
    this.margin = 300,
  });

  @override
  State<LazyMount> createState() => _LazyMountState();
}

class _LazyMountState extends State<LazyMount> {
  bool _mounted = false;
  ScrollPosition? _position;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final pos = Scrollable.maybeOf(context)?.position;
    if (pos != _position) {
      _position?.removeListener(_onScroll);
      _position = pos;
      _position?.addListener(_onScroll);
    }
  }

  void _onScroll() {
    if (!_mounted) _check();
  }

  void _check() {
    if (_mounted || !mounted) return;
    if (_isVisible()) {
      setState(() => _mounted = true);
      _position?.removeListener(_onScroll);
    }
  }

  bool _isVisible() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return false;
    final myRect = box.localToGlobal(Offset.zero) & box.size;

    final scrollable = Scrollable.maybeOf(context);
    final vpBox = scrollable?.context.findRenderObject() as RenderBox?;
    final vpRect = vpBox != null && vpBox.attached
        ? (vpBox.localToGlobal(Offset.zero) & vpBox.size)
        : (Offset.zero & MediaQuery.of(context).size);

    return myRect.overlaps(vpRect.inflate(widget.margin));
  }

  @override
  void dispose() {
    _position?.removeListener(_onScroll);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_mounted) return widget.builder(context);
    // Tapping the placeholder force-mounts, in case the heuristic misses.
    return GestureDetector(
      onTap: () => setState(() => _mounted = true),
      child: widget.placeholder,
    );
  }
}
