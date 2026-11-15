// DEV-ONLY: the 2.5D change navigation for one real change, walked by itself.
//
//   flutter run -d linux -t lib/dev/indoor_nav_demo.dart \
//     --dart-define=STATION=Hamburg-Harburg --dart-define=FROM=5 --dart-define=TO=11
//
// With --dart-define=RECORD_DIR=/abs/dir it writes every frame as PNG and
// quits; tool/indoor_demo.sh turns that into an MP4.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../core/indoor_nav/indoor_route.dart';
import '../models/station_map.dart';
import '../screens/station_map/indoor_nav_screen.dart';
import '../services/station_map_service.dart';

const _station = String.fromEnvironment(
  'STATION',
  defaultValue: 'Hamburg-Harburg',
);
const _from = String.fromEnvironment('FROM', defaultValue: '5');
const _to = String.fromEnvironment('TO', defaultValue: '11');
const _record = String.fromEnvironment('RECORD_DIR');

void main() => runApp(
  MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorSchemeSeed: const Color(0xFFEC0016),
    ),
    home: const _Demo(),
  ),
);

class _Demo extends StatefulWidget {
  const _Demo();
  @override
  State<_Demo> createState() => _DemoState();
}

class _DemoState extends State<_Demo> {
  StationMap? _map;
  IndoorRoute? _route;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final map = await StationMapService().fetchByStationName(_station);
      MapPoi g(String n) => map.platforms.firstWhere((p) => p.name == n);
      final route = planIndoorRoute(map: map, start: g(_from), target: g(_to));
      setState(() {
        _map = map;
        _route = route;
        if (route == null) _error = 'Keine Route';
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Scaffold(body: Center(child: Text(_error!)));
    if (_route == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return IndoorNavScreen(
      map: _map!,
      route: _route!,
      stationName: _station,
      demo: true,
      recordDir: _record.isEmpty ? null : _record,
      tileProvider: () => NetworkTileProvider(
        headers: {'Referer': 'https://www.bahnhof.de/'},
      ),
    );
  }
}
