import 'package:besser_bahn/models/station.dart';
import 'package:besser_bahn/providers/station_map_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('#54 — the Bahnhof tab\'s map and a trip\'s map are separate', () {
    test('opening a stop from a trip leaves the tab\'s station alone', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);

      // The rider browsed to Kiel Hbf on the Bahnhof tab...
      unawaited(c
          .read(stationMapProvider.notifier)
          .loadForStation(const Station(id: '8000199', name: 'Kiel Hbf')));
      // ...then opened the Einstieg-Gleis of a trip stopping in Hamburg.
      unawaited(c.read(dedicatedStationMapProvider.notifier).loadForStation(
            const Station(id: '8002549', name: 'Hamburg Hbf'),
            highlightGleis: '14',
          ));

      expect(c.read(stationMapProvider).station?.name, 'Kiel Hbf',
          reason: 'the tab used to be dragged along to the trip\'s station');
      expect(c.read(stationMapProvider).highlightGleis, isNull,
          reason: 'the tab is browsing, it has no boarding Gleis');
      expect(c.read(dedicatedStationMapProvider).station?.name, 'Hamburg Hbf');
      expect(c.read(dedicatedStationMapProvider).highlightGleis, '14');
    });
  });
}

/// The loads fire a network fetch we neither await nor need — only the state
/// they set synchronously is under test.
void unawaited(Future<void> f) {
  f.catchError((_) {});
}
