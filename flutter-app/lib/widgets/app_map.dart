import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/app_log.dart';
import '../core/tile_cache.dart';
import '../models/station_map.dart';
import '../services/location_service.dart';
import '../theme/app_colors.dart';

/// Shared base for every map in the app (Bahnhofskarte, Streckenverlauf,
/// Abfahrten/Umgebung). It owns the things every map should have and look the
/// same doing: the cached outdoor base tiles, an optional bahnhof.de indoor
/// floor layer, a metric scale bar, and the attribution. Each screen just
/// passes its own [children] (route/train/POI/locate layers) on top.
class AppMap extends StatelessWidget {
  final MapController? controller;
  final LatLng? initialCenter;
  final double initialZoom;
  final double minZoom;
  final double maxZoom;
  final CameraFit? initialCameraFit;

  /// Pan/zoom enabled. Rotation is off by default (the indoor plans are
  /// north-up and a stray two-finger twist just disorients).
  final bool interactive;
  final bool allowRotation;
  final void Function(TapPosition, LatLng)? onTap;

  /// Camera moved (pan/zoom). Lets a map lazily load detail for whatever the
  /// rider has navigated to — e.g. the route map fetches a stop's platform only
  /// once it's zoomed into view, instead of prefetching the whole route upfront.
  final void Function(MapCamera camera, bool hasGesture)? onPositionChanged;

  /// A bahnhof.de floor id (e.g. `GROUND_FLOOR`) → overlay the real indoor
  /// floor plan. Null for an outdoor-only map.
  final String? indoorLevel;

  /// Credit the DB InfraGO floor plan (only when an indoor layer is shown).
  final bool dbAttribution;

  /// The map-specific layers, drawn above the base tiles and below the
  /// scale bar / attribution.
  final List<Widget> children;

  const AppMap({
    super.key,
    this.controller,
    this.initialCenter,
    this.initialZoom = 17,
    this.minZoom = 10,
    this.maxZoom = 20,
    this.initialCameraFit,
    this.interactive = true,
    this.allowRotation = false,
    this.onTap,
    this.onPositionChanged,
    this.indoorLevel,
    this.dbAttribution = false,
    this.children = const [],
  });

  @override
  Widget build(BuildContext context) {
    final showIndoor = indoorLevel != null && indoorLevel!.isNotEmpty;
    return FlutterMap(
      mapController: controller,
      options: MapOptions(
        initialCenter: initialCenter ?? const LatLng(51.1657, 10.4515),
        initialZoom: initialZoom,
        minZoom: minZoom,
        maxZoom: maxZoom,
        initialCameraFit: initialCameraFit,
        onTap: onTap,
        onPositionChanged: onPositionChanged,
        interactionOptions: InteractionOptions(
          flags: !interactive
              ? InteractiveFlag.none
              : (allowRotation
                    ? InteractiveFlag.all
                    : InteractiveFlag.all & ~InteractiveFlag.rotate),
        ),
      ),
      children: [
        // Base + indoor tiles are dropped while AppLog.tilesPaused is true (a
        // tile host went hammering-unreachable) so neither layer can keep firing
        // doomed requests and choke the connection; they remount when it clears.
        ValueListenableBuilder<bool>(
          valueListenable: AppLog.tilesPaused,
          builder: (_, paused, child) =>
              paused ? const SizedBox.shrink() : TileCache.outdoorLayer(),
        ),
        if (showIndoor)
          ValueListenableBuilder<bool>(
            valueListenable: AppLog.tilesPaused,
            builder: (_, paused, child) => paused
                ? const SizedBox.shrink()
                : _IndoorLayer(level: indoorLevel!),
          ),
        ...children,
        const Scalebar(
          alignment: Alignment.bottomRight,
          padding: EdgeInsets.only(right: 12, bottom: 20),
        ),
        RichAttributionWidget(
          alignment: AttributionAlignment.bottomLeft,
          // The default flutter_map logo is a package asset that isn't bundled →
          // it spams "Unable to load AssetManifest.bin". Disable.
          showFlutterMapAttribution: false,
          attributions: [
            const TextSourceAttribution('© OpenStreetMap'),
            const TextSourceAttribution('© OpenMapTiles'),
            if (dbAttribution)
              const TextSourceAttribution('Bahnhofsplan © DB InfraGO'),
          ],
        ),
      ],
    );
  }
}

/// The bahnhof.de floor plan, only from [_IndoorLayer.minZoom] on.
///
/// The plan's tiles exist from zoom 14 (`minNativeZoom`). flutter_map serves a
/// lower map zoom by loading the NATIVE z14 tiles for the whole viewport and
/// scaling them down, and neither its `minZoom` nor unmounting the layer stops
/// that: the layer reacts to a camera move before the rebuild that would remove
/// it. The route map hit exactly that on open — first frame at the default
/// zoom 17, then the fit to the whole run at zoom ~7 — and loaded ~1800 z14
/// tiles at once: RAM jumped by ~1 GB, the map stalled, and the queued
/// downloads kept the app slow after leaving it (2026-11-13, measured on the
/// ICE 775 map).
///
/// Two guards, both needed: the layer is not in the tree below [minZoom]
/// (cheap overview), and its tile provider asks the LIVE camera for every
/// single tile and serves a blank one while zoomed out.
class _IndoorLayer extends StatefulWidget {
  final String level;
  const _IndoorLayer({required this.level});

  static const minZoom = 14.0;

  @override
  State<_IndoorLayer> createState() => _IndoorLayerState();
}

class _IndoorLayerState extends State<_IndoorLayer> {
  MapController? _controller;

  // One provider for the layer's life: this widget rebuilds on every camera
  // move, and a new provider instance would make the TileLayer start over.
  // TileLayer disposes its provider on unmount, and the base dispose is a
  // no-op, so remounting it later is safe.
  late final TileProvider _provider = TileCache.provider(
    headers: {'Referer': 'https://www.bahnhof.de/'},
    allow: () {
      final zoom = _controller?.camera.zoom;
      return zoom != null && zoom >= _IndoorLayer.minZoom;
    },
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller = MapController.maybeOf(context);
  }

  @override
  Widget build(BuildContext context) {
    final zoom = MapCamera.of(context).zoom;
    if (zoom < _IndoorLayer.minZoom) return const SizedBox.shrink();
    return TileLayer(
      urlTemplate: StationMap.indoorTileUrl(widget.level),
      tileDimension: 256,
      minNativeZoom: 14,
      maxNativeZoom: 18,
      maxZoom: 20,
      tileProvider: _provider,
      userAgentPackageName: 'de.chuk.besserebahn',
      errorTileCallback: (_, _, _) {},
    );
  }
}

/// The "Mein Standort" overlay layers — the line to [target], the GPS accuracy
/// circle, and the blue dot. Shared by every map that locates the user, so
/// they're drawn identically everywhere.
///
/// [walkingRoute] is DB's real walking route (#21). When it's there the line
/// follows the way you'd actually walk and is drawn solid; without it the line
/// stays the dotted straight one — dotted precisely because it's a direction,
/// not a route, and a solid line through the middle of a station building would
/// claim to be one.
List<Widget> mapLocateLayers({
  required UserFix fix,
  required LatLng target,
  List<LatLng>? walkingRoute,
}) => [
  PolylineLayer(
    polylines: [
      Polyline(
        points: (walkingRoute != null && walkingRoute.length >= 2)
            ? walkingRoute
            : [fix.latLng, target],
        color: AppColors.dbBlue.withAlpha(180),
        strokeWidth: 4,
        pattern: (walkingRoute != null && walkingRoute.length >= 2)
            ? const StrokePattern.solid()
            : StrokePattern.dotted(),
      ),
    ],
  ),
  CircleLayer(
    circles: [
      CircleMarker(
        point: fix.latLng,
        radius: fix.accuracy,
        useRadiusInMeter: true,
        color: AppColors.dbBlue.withAlpha(30),
        borderColor: AppColors.dbBlue.withAlpha(90),
        borderStrokeWidth: 1,
      ),
    ],
  ),
  MarkerLayer(
    markers: [
      Marker(
        point: fix.latLng,
        width: 22,
        height: 22,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.dbBlue,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [
              BoxShadow(color: Colors.black26, blurRadius: 4, spreadRadius: 1),
            ],
          ),
        ),
      ),
    ],
  ),
];

/// The round "Mein Standort" button shared by the locating maps.
class MapLocateButton extends StatelessWidget {
  final bool busy;
  final VoidCallback? onPressed;
  final String heroTag;
  const MapLocateButton({
    super.key,
    required this.busy,
    required this.onPressed,
    this.heroTag = 'locate-me',
  });

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.small(
      heroTag: heroTag,
      tooltip: 'Mein Standort',
      onPressed: busy ? null : onPressed,
      child: busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.my_location),
    );
  }
}
