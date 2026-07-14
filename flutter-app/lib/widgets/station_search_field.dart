import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/station.dart';
import '../providers/library_provider.dart';
import '../providers/station_search_provider.dart';
import '../utils/geo_query.dart';

class StationSearchField extends ConsumerStatefulWidget {
  final String hint;
  final Station? initialStation;
  final ValueChanged<Station> onSelected;
  final IconData? prefixIcon;
  final TextEditingController? controller;

  /// Compact rendering: smaller height, tighter padding, smaller icons — used
  /// where the form must stay tight (the connection search header).
  final bool dense;

  const StationSearchField({
    super.key,
    required this.hint,
    this.initialStation,
    required this.onSelected,
    this.prefixIcon,
    this.controller,
    this.dense = false,
  });

  @override
  ConsumerState<StationSearchField> createState() =>
      _StationSearchFieldState();
}

class _StationSearchFieldState extends ConsumerState<StationSearchField> {
  late TextEditingController _controller;
  bool _ownsController = false;
  final _focusNode = FocusNode();
  final _layerLink = LayerLink();
  OverlayEntry? _overlay;
  bool _suppressDismiss = false;

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      _controller = widget.controller!;
    } else {
      _controller = TextEditingController();
      _ownsController = true;
    }
    if (widget.initialStation != null && _controller.text.isEmpty) {
      _controller.text = widget.initialStation!.name;
    }
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(StationSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialStation != oldWidget.initialStation &&
        widget.initialStation != null) {
      _controller.text = widget.initialStation!.name;
    }
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus) {
      // Surface favorites/recents (or live results) as soon as the field is
      // focused, even before the user types.
      _showOverlay();
      return;
    }
    if (!_suppressDismiss) {
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted && !_focusNode.hasFocus) {
          _removeOverlay();
        }
      });
    }
  }

  void _selectStation(Station station) {
    _suppressDismiss = true;
    _controller.text = station.name;
    ref.read(libraryProvider.notifier).recordStationUse(station);
    widget.onSelected(station);
    _removeOverlay();
    _focusNode.unfocus();
    ref.read(stationSearchProvider.notifier).clear();
    setState(() {});
    Future.delayed(const Duration(milliseconds: 100), () {
      _suppressDismiss = false;
    });
  }

  void _showOverlay() {
    _removeOverlay();
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    _overlay = OverlayEntry(
      builder: (context) => Positioned(
        width: renderBox.size.width,
        child: CompositedTransformFollower(
          link: _layerLink,
          offset: Offset(0, renderBox.size.height + 4),
          showWhenUnlinked: false,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: Consumer(
              builder: (context, ref, _) {
                final query = _controller.text.trim();
                final geo = parseGeoQuery(query);
                // Short query → suggest saved favorites and recent stations.
                // A coordinate is exempt: "geo:52.5,13.3" is already complete,
                // and a pasted one can be shorter than a station name.
                if (geo == null && query.length < 2) {
                  return _buildSuggestions(ref);
                }
                final results = ref.watch(stationSearchProvider);
                return results.when(
                  data: (stations) {
                    if (stations.isEmpty) {
                      // Say so rather than showing nothing: a coordinate in the
                      // sea or abroad has no stops near it, and silence would
                      // read as "still loading".
                      return geo == null
                          ? const SizedBox.shrink()
                          : _geoNotice(context,
                              'Keine Haltestellen in der Nähe dieser Koordinate.');
                    }
                    return ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 320),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (geo != null)
                            _geoNotice(
                                context,
                                geo.label != null
                                    ? 'Haltestellen nahe „${geo.label}"'
                                    : 'Haltestellen in der Nähe der Koordinate'),
                          Flexible(
                            child: ListView.builder(
                              padding: EdgeInsets.zero,
                              shrinkWrap: true,
                              itemCount: stations.length,
                              itemBuilder: (context, index) =>
                                  _stationTile(ref, stations[index]),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                  loading: () => const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                        child: SizedBox(
                            height: 24,
                            width: 24,
                            child: CircularProgressIndicator(strokeWidth: 2))),
                  ),
                  error: (_, __) => const SizedBox.shrink(),
                );
              },
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_overlay!);
  }

  Widget _buildSuggestions(WidgetRef ref) {
    final library = ref.watch(libraryProvider);
    final favorites = library.favorites;
    final recents = library.recents;
    if (favorites.isEmpty && recents.isEmpty) return const SizedBox.shrink();

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 320),
      child: ListView(
        padding: EdgeInsets.zero,
        shrinkWrap: true,
        children: [
          if (favorites.isNotEmpty) ...[
            _sectionHeader('Favoriten'),
            ...favorites.map((s) => _stationTile(ref, s)),
          ],
          if (recents.isNotEmpty) ...[
            _sectionHeader('Zuletzt gesucht'),
            ...recents.map((s) => _stationTile(ref, s)),
          ],
        ],
      ),
    );
  }

  Widget _sectionHeader(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );

  /// Header above coordinate-derived results, explaining why this list is
  /// nearby stops rather than name matches.
  Widget _geoNotice(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Row(
        children: [
          Icon(Icons.my_location, size: 15, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }

  Widget _stationTile(WidgetRef ref, Station station) {
    final isFav = ref.watch(libraryProvider).isStationFavorite(station.id);
    return ListTile(
      dense: true,
      leading: const Icon(Icons.train, size: 20),
      title: Text(station.name, style: const TextStyle(fontSize: 14)),
      trailing: IconButton(
        icon: Icon(
          isFav ? Icons.star : Icons.star_border,
          size: 20,
          color: isFav ? Colors.amber.shade700 : null,
        ),
        tooltip: isFav ? 'Favorit entfernen' : 'Als Favorit speichern',
        onPressed: () {
          _suppressDismiss = true;
          ref.read(libraryProvider.notifier).toggleStationPin(station);
          Future.delayed(const Duration(milliseconds: 100), () {
            _suppressDismiss = false;
          });
        },
      ),
      onTap: () => _selectStation(station),
    );
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  @override
  void dispose() {
    _removeOverlay();
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  /// Auto-select a station once the typed/pasted text clearly identifies one:
  /// an exact case-insensitive name match, or a single remaining result that
  /// the text is a prefix of. Saves the user from having to tap the dropdown.
  void _maybeAutoSelect(List<Station> stations) {
    final typed = _controller.text.trim().toLowerCase();
    if (typed.length < 3 || stations.isEmpty) return;

    // Only one option left → that's the answer.
    if (stations.length == 1 &&
        stations.first.name.toLowerCase().startsWith(typed)) {
      _selectStation(stations.first);
      return;
    }

    // Exact name match — but ONLY if it's unambiguous, i.e. no other result
    // extends it (so "Berlin" doesn't auto-pick while "Berlin Hauptbahnhof",
    // "Berlin Ostbahnhof" … are still candidates; "Kiel Hauptbahnhof" does).
    final exact =
        stations.where((s) => s.name.toLowerCase() == typed).toList();
    if (exact.length == 1) {
      final extendedByOther = stations.any((s) =>
          s.name.length > typed.length &&
          s.name.toLowerCase().startsWith(typed));
      if (!extendedByOther) _selectStation(exact.first);
    }
  }

  @override
  Widget build(BuildContext context) {
    // React to fresh search results (also after a paste) and auto-match.
    ref.listen(stationSearchProvider, (_, next) {
      next.whenData(_maybeAutoSelect);
    });

    return CompositedTransformTarget(
      link: _layerLink,
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        style: widget.dense ? const TextStyle(fontSize: 14) : null,
        decoration: InputDecoration(
          hintText: widget.hint,
          isDense: widget.dense,
          contentPadding: widget.dense
              ? const EdgeInsets.symmetric(horizontal: 8, vertical: 8)
              : null,
          prefixIcon: widget.prefixIcon != null
              ? Icon(widget.prefixIcon, size: widget.dense ? 18 : null)
              : null,
          prefixIconConstraints: widget.dense
              ? const BoxConstraints(minWidth: 36, minHeight: 36)
              : null,
          suffixIcon: _controller.text.isNotEmpty
              ? IconButton(
                  icon: Icon(Icons.clear, size: widget.dense ? 18 : 20),
                  visualDensity:
                      widget.dense ? VisualDensity.compact : null,
                  onPressed: () {
                    _controller.clear();
                    ref.read(stationSearchProvider.notifier).clear();
                    // Keep the overlay so favorites/recents show again.
                    if (_focusNode.hasFocus) _showOverlay();
                    setState(() {});
                  },
                )
              : null,
          suffixIconConstraints: widget.dense
              ? const BoxConstraints(minWidth: 36, minHeight: 36)
              : null,
        ),
        onChanged: (value) {
          ref.read(stationSearchProvider.notifier).search(value);
          _showOverlay();
          setState(() {});
        },
      ),
    );
  }
}
