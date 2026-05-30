import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

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
        interactionOptions: InteractionOptions(
          flags: !interactive
              ? InteractiveFlag.none
              : (allowRotation
                  ? InteractiveFlag.all
                  : InteractiveFlag.all & ~InteractiveFlag.rotate),
        ),
      ),
      children: [
        TileCache.outdoorLayer(),
        if (showIndoor)
          TileLayer(
            urlTemplate: StationMap.indoorTileUrl(indoorLevel!),
            tileDimension: 256,
            minNativeZoom: 14,
            maxNativeZoom: 18,
            maxZoom: 20,
            tileProvider: TileCache.provider(
              headers: {'Referer': 'https://www.bahnhof.de/'},
            ),
            userAgentPackageName: 'de.chuk.besserebahn',
            errorTileCallback: (_, _, _) {},
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

/// The "Mein Standort" overlay layers — the dotted direction line to [target],
/// the GPS accuracy circle, and the blue dot. Shared by every map that locates
/// the user, so they're drawn identically everywhere.
List<Widget> mapLocateLayers({required UserFix fix, required LatLng target}) => [
      PolylineLayer(
        polylines: [
          Polyline(
            points: [fix.latLng, target],
            color: AppColors.dbBlue.withAlpha(180),
            strokeWidth: 4,
            pattern: StrokePattern.dotted(),
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
      MarkerLayer(markers: [
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
      ]),
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
