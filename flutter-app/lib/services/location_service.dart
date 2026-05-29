import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

/// Thrown when we can't get the user's position, with a German message ready
/// to show in a SnackBar.
class LocationException implements Exception {
  final String message;
  const LocationException(this.message);
  @override
  String toString() => message;
}

/// A fix: the user's position plus its horizontal accuracy (metres).
class UserFix {
  final LatLng latLng;
  final double accuracy;
  const UserFix(this.latLng, this.accuracy);
}

/// Thin wrapper over `geolocator`: checks the location service + permission,
/// then returns a single fix. Keeps all the permission/error wording in one
/// place so the UI just shows what we throw.
class LocationService {
  /// Resolve the current device position, requesting permission if needed.
  /// Throws [LocationException] with a user-facing German message on failure.
  Future<UserFix> currentFix() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const LocationException(
        'Standortdienste sind aus. Bitte in den Geräteeinstellungen aktivieren.',
      );
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      throw const LocationException(
        'Standortzugriff abgelehnt. Tippe erneut, um zu erlauben.',
      );
    }
    if (permission == LocationPermission.deniedForever) {
      throw const LocationException(
        'Standortzugriff dauerhaft abgelehnt. Bitte in den App-Einstellungen '
        'erlauben.',
      );
    }

    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
      ),
    );
    return UserFix(LatLng(pos.latitude, pos.longitude), pos.accuracy);
  }
}
