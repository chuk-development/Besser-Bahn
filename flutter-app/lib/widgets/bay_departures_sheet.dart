import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/extensions.dart';
import '../models/departure.dart';
import '../models/station_map.dart';
import '../providers/service_providers.dart';
import '../providers/train_lookup_provider.dart';
import 'delay_badge.dart';

/// POI categories that have live departures we can show for a specific bay.
const kDepartureCategories = {
  'PLATFORM',
  'BUS',
  'TRAM',
  'SUBWAY',
  'CITY_TRAIN',
  'RAIL_REPLACEMENT_TRANSPORT',
};

/// Normalise a track/bay label to its base id, dropping the platform SECTION
/// suffix that the departure board adds but the map omits:
/// "6A-C" → "6", "1 A - D" → "1", "13D-F" → "13", "A2" → "A2".
/// This is what makes the match work for trains at every station.
String normBay(String g) {
  g = g.trim();
  if (g.isEmpty) return g;
  if (RegExp(r'^\d').hasMatch(g)) {
    return RegExp(r'^\d+').firstMatch(g)!.group(0)!; // leading track number
  }
  return g.split(RegExp(r'\s+')).first.toUpperCase(); // e.g. bus bay "A2"
}

/// Departure products that belong to a POI's transport mode.
Set<String> bayModeProducts(String poiType) {
  switch (poiType) {
    case 'BUS':
    case 'RAIL_REPLACEMENT_TRANSPORT':
      return {'bus'};
    case 'TRAM':
      return {'tram'};
    case 'SUBWAY':
      return {'subway'};
    case 'CITY_TRAIN':
      return {'suburban'};
    case 'PLATFORM': // a Gleis carries trains (incl. S-Bahn)
      return {'nationalExpress', 'national', 'regional', 'suburban'};
    default:
      return {};
  }
}

/// German label for a POI's mode, for the "all departures" fallback header.
String bayModeLabel(String poiType) {
  switch (poiType) {
    case 'BUS':
      return 'Bus';
    case 'RAIL_REPLACEMENT_TRANSPORT':
      return 'SEV';
    case 'TRAM':
      return 'Tram';
    case 'SUBWAY':
      return 'U-Bahn';
    case 'CITY_TRAIN':
      return 'S-Bahn';
    case 'PLATFORM':
      return 'Zug';
    default:
      return '';
  }
}

/// Does a departure leave from this POI's bay/track?
bool poiMatchesDeparture(MapPoi poi, Departure d) {
  final raw = (d.platform ?? '').trim();
  if (raw.isEmpty) return false;
  final base = normBay(raw);
  if (poi.isPlatform) {
    return normBay(poi.name) == base;
  }
  // Transit bay: the base id must appear as a whole token in the bay label
  // (so "C2" doesn't match "C20", and "1" matches "Bussteig [H]1/[H]3").
  final hay = '${poi.detail ?? ''} ${poi.name}';
  bool token(String t) =>
      t.isNotEmpty &&
      RegExp('(^|[^0-9A-Za-z])${RegExp.escape(t)}([^0-9A-Za-z]|\$)')
          .hasMatch(hay);
  return token(base) || token(raw);
}

/// The departures (from an already-loaded board) that leave from [poi],
/// restricted to the POI's transport mode then matched to its bay/track.
/// Empty when none match — used to badge map markers.
List<Departure> departuresForPoi(MapPoi poi, List<Departure> all) {
  final products = bayModeProducts(poi.type);
  final modeDeps = products.isEmpty
      ? all
      : all.where((d) => products.contains(d.line.product)).toList();
  return modeDeps.where((d) => poiMatchesDeparture(poi, d)).toList();
}

/// Product colour (ICE red, S green, U blue, Bus violet …).
Color bayProductColor(String product) {
  switch (product) {
    case 'nationalExpress':
      return const Color(0xFFEC0016); // dbRed
    case 'national':
      return const Color(0xFFEC6608);
    case 'regional':
      return const Color(0xFF646973);
    case 'suburban':
      return const Color(0xFF008D4F);
    case 'subway':
      return const Color(0xFF1455C0);
    case 'tram':
      return const Color(0xFFBE1414);
    case 'bus':
      return const Color(0xFFA9469B);
    case 'ferry':
      return const Color(0xFF0087B8);
    default:
      return Colors.blueGrey;
  }
}

class _BayResult {
  final List<Departure> deps;
  final bool matchedBay; // true = filtered to this bay; false = all departures
  const _BayResult(this.deps, this.matchedBay);
}

/// Bottom sheet listing the live departures from one Gleis / transit bay.
/// Tapping a departure opens its full run on the train screen.
class BayDeparturesSheet extends ConsumerStatefulWidget {
  final String stationEva;
  final MapPoi poi;

  const BayDeparturesSheet({
    super.key,
    required this.stationEva,
    required this.poi,
  });

  @override
  ConsumerState<BayDeparturesSheet> createState() => _BayDeparturesSheetState();
}

class _BayDeparturesSheetState extends ConsumerState<BayDeparturesSheet> {
  late Future<_BayResult> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_BayResult> _load() async {
    final hafas = ref.read(hafasServiceProvider);

    // Universal stop resolution: a bay may physically belong to a different
    // stop than the searched station (e.g. a ZOB or U-Bahn with its own EVA).
    // Resolve the nearest stop to the POI's coordinates and query *its* board,
    // so this works for any station without a hand-maintained mapping.
    var eva = widget.stationEva;
    final poi = widget.poi;
    // Only transit bays may belong to a different stop (ZOB, U-Bahn). Train
    // Gleise always belong to the searched rail station, so don't re-resolve
    // them (a nearby bus stop would otherwise hijack them).
    if (!poi.isPlatform) {
      try {
        final near = await hafas.nearbyStations(
          latitude: poi.latitude,
          longitude: poi.longitude,
          results: 1,
          distance: 150,
        );
        if (near.isNotEmpty && near.first.id.isNotEmpty) {
          eva = near.first.id;
        }
      } catch (_) {/* keep searched-station eva */}
    }

    final all = await hafas.getDepartures(eva, results: 100);

    // 1) Restrict to the POI's transport mode FIRST — otherwise a bus bay
    //    labelled "1/3" would wrongly match railway platform "1" (a train).
    final products = bayModeProducts(widget.poi.type);
    final modeDeps = products.isEmpty
        ? all
        : all.where((d) => products.contains(d.line.product)).toList();

    // 2) Within that mode, match the specific bay/track.
    final matched =
        modeDeps.where((d) => poiMatchesDeparture(widget.poi, d)).toList();
    if (matched.isNotEmpty) return _BayResult(matched, true);

    // 3) Bay label couldn't be matched (e.g. multi-level ZOB uses a different
    //    numbering than the operator) → show all departures of the SAME mode,
    //    never a different mode, so a bus bay never shows trains.
    return _BayResult(modeDeps, false);
  }

  void _openTrain(Departure d) {
    ref.read(trainLookupProvider.notifier).lookupByTripId(d.tripId);
    Navigator.of(context).pop();
    context.go('/train');
  }

  @override
  Widget build(BuildContext context) {
    final bayLabel = widget.poi.isPlatform
        ? 'Gleis ${widget.poi.name}'
        : (widget.poi.detail ?? widget.poi.name);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return FutureBuilder<_BayResult>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final res = snap.data;
            final deps = res?.deps ?? const <Departure>[];
            final title = (res?.matchedBay ?? true)
                ? 'Abfahrten $bayLabel'
                : 'Abfahrten ${widget.poi.name == 'Bus' ? 'Bus' : bayLabel}';
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (res != null && !res.matchedBay)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      'Steig „$bayLabel“ ließ sich nicht eindeutig zuordnen – '
                      'alle ${bayModeLabel(widget.poi.type)}-Abfahrten (Steig je Zeile):',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                Expanded(
                  child: deps.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('Aktuell keine Abfahrten.',
                                textAlign: TextAlign.center),
                          ),
                        )
                      : ListView.separated(
                          controller: scrollController,
                          itemCount: deps.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) => _DepartureRow(
                            dep: deps[i],
                            showBay: !(res?.matchedBay ?? true),
                            onTap: () => _openTrain(deps[i]),
                          ),
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _DepartureRow extends StatelessWidget {
  final Departure dep;
  final VoidCallback onTap;
  final bool showBay;
  const _DepartureRow(
      {required this.dep, required this.onTap, this.showBay = false});

  @override
  Widget build(BuildContext context) {
    final time = (dep.when ?? dep.plannedWhen)?.hhmm ?? '';
    final bay = dep.platform;
    final sub = [
      if (dep.line.displayName.isNotEmpty) dep.line.displayName,
      if (showBay && bay != null && bay.isNotEmpty) 'Steig $bay',
    ].join('  ·  ');
    return ListTile(
      onTap: onTap,
      leading: _LineChip(dep: dep),
      title:
          Text(dep.direction, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: sub.isNotEmpty ? Text(sub) : null,
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(time, style: const TextStyle(fontWeight: FontWeight.w600)),
          DelayBadge(delaySeconds: dep.delay, cancelled: dep.cancelled),
        ],
      ),
    );
  }
}

/// Small coloured product chip (ICE red, S green, U blue, Bus violet …).
class _LineChip extends StatelessWidget {
  final Departure dep;
  const _LineChip({required this.dep});

  @override
  Widget build(BuildContext context) {
    final color = bayProductColor(dep.line.product);
    final label = dep.line.productName.isNotEmpty
        ? dep.line.productName
        : dep.line.displayName;
    return Container(
      width: 44,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: Text(
        label.length > 5 ? label.substring(0, 5) : label,
        style: const TextStyle(
            color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
        maxLines: 1,
      ),
    );
  }
}
