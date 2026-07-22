import 'package:besser_bahn/models/journey.dart';
import 'package:besser_bahn/models/library_models.dart';
import 'package:besser_bahn/providers/library_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lets the library's SharedPreferences read/write settle before asserting.
Future<void> _settle() => Future.delayed(const Duration(milliseconds: 10));

Journey _journey() => Journey.fromJson({
      'legs': [
        {
          'origin': {'id': '8000199', 'name': 'Kiel Hbf'},
          'destination': {'id': '8002549', 'name': 'Hamburg Hbf'},
          'plannedDeparture': '2026-08-01T10:00:00.000',
          'plannedArrival': '2026-08-01T11:15:00.000',
        }
      ],
    });

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('#51 — "Rückgängig" after a swipe delete', () {
    test('a removed trip comes back exactly as it was', () async {
      final c = ProviderContainer();
      final lib = c.read(libraryProvider.notifier);
      lib.toggleJourney(_journey());
      await _settle();
      final entry = c.read(libraryProvider).journeys.single;
      lib.setJourneyWatched(entry.key, false);
      final before = c.read(libraryProvider).journeys.single;

      lib.removeJourney(before.key);
      expect(c.read(libraryProvider).journeys, isEmpty);

      lib.restoreJourney(before);
      await _settle();

      final after = c.read(libraryProvider).journeys.single;
      expect(after.key, before.key);
      expect(after.savedAtMs, before.savedAtMs,
          reason: 'undo must restore the trip, not re-save it as new');
      expect(after.watched, isFalse,
          reason: 'the per-trip bell setting is part of the trip');
      c.dispose();
    });

    test('the restored trip survives a restart', () async {
      final c1 = ProviderContainer();
      final lib = c1.read(libraryProvider.notifier);
      lib.toggleJourney(_journey());
      await _settle();
      final entry = c1.read(libraryProvider).journeys.single;
      lib.removeJourney(entry.key);
      lib.restoreJourney(entry);
      await _settle();
      c1.dispose();

      final c2 = ProviderContainer();
      c2.read(libraryProvider);
      await _settle();
      expect(c2.read(libraryProvider).journeys.single.key, entry.key,
          reason: 'an undo that only lives in memory is no undo');
      c2.dispose();
    });

    test('restoring a trip that is already there does not duplicate it',
        () async {
      final c = ProviderContainer();
      final lib = c.read(libraryProvider.notifier);
      lib.toggleJourney(_journey());
      await _settle();
      final entry = c.read(libraryProvider).journeys.single;

      lib.restoreJourney(entry);
      await _settle();

      expect(c.read(libraryProvider).journeys, hasLength(1),
          reason: 'two entries for one trip = every reminder twice');
      c.dispose();
    });
  });
}
