import 'package:besser_bahn/models/journey.dart';
import 'package:besser_bahn/models/library_models.dart';
import 'package:besser_bahn/providers/library_provider.dart';
import 'package:besser_bahn/services/trip_reminder_scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lets the library's SharedPreferences read/write settle before asserting.
Future<void> _settle() => Future.delayed(const Duration(milliseconds: 10));

final _base = DateTime(2026, 8, 1, 10, 0);

Map<String, dynamic> _legJson({
  required String originId,
  required String originName,
  required String destId,
  required String destName,
  required DateTime departure,
  required DateTime arrival,
  String line = 'ICE 71',
}) =>
    {
      'origin': {'id': originId, 'name': originName},
      'destination': {'id': destId, 'name': destName},
      'plannedDeparture': departure.toIso8601String(),
      'plannedArrival': arrival.toIso8601String(),
      'line': {'name': line},
    };

/// Kiel → Hamburg, departing [departure].
Journey _journey({DateTime? departure}) {
  final dep = departure ?? _base;
  return Journey.fromJson({
    'legs': [
      _legJson(
        originId: '8000199',
        originName: 'Kiel Hbf',
        destId: '8002549',
        destName: 'Hamburg Hbf',
        departure: dep,
        arrival: dep.add(const Duration(minutes: 75)),
      ),
    ],
  });
}

/// The same trip but boarding a later train — what a leg swap produces.
Journey _swapped() => _journey(departure: _base.add(const Duration(hours: 2)));

SavedJourney _saved(Journey journey, {bool watched = true}) =>
    SavedJourney(journey: journey, savedAtMs: 7, watched: watched);

List<TripReminder> _plan(List<SavedJourney> trips) => TripReminderScheduler.plan(
      trips,
      leadMinutes: 30,
      departureReminders: true,
      transferAlerts: true,
      arrivalAlert: true,
      arrivalAlarmSound: false,
      now: _base.subtract(const Duration(hours: 3)),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('#58 — an abandoned connection stops notifying', () {
    test('a watched trip is planned as before', () {
      expect(_plan([_saved(_journey())]), isNotEmpty);
    });

    test('switching a trip off cancels its scheduled reminders too', () {
      // The bell used to gate only the live companion, so the OS-scheduled
      // pings kept arriving for the connection the rider had given up on.
      expect(_plan([_saved(_journey(), watched: false)]), isEmpty,
          reason: 'the abandoned connection must go quiet on every channel');
    });

    test('switching one trip off leaves the others alone', () {
      final plan = _plan([
        _saved(_journey(), watched: false),
        _saved(_swapped()),
      ]);
      expect(plan, isNotEmpty);
      // Every remaining ping belongs to the replacement (12:00), not the
      // abandoned 10:00 train.
      for (final r in plan) {
        expect(r.when.isAfter(_base), isTrue,
            reason: 'ping at ${r.when} still belongs to the dropped trip');
      }
    });
  });

  group('#58 — a swapped leg follows the saved trip', () {
    test('replaceJourney swaps the itinerary and keeps save time + bell',
        () async {
      final c = ProviderContainer();
      final lib = c.read(libraryProvider.notifier);
      lib.toggleJourney(_journey());
      await _settle();
      final oldKey = _saved(_journey()).key;
      lib.setJourneyWatched(oldKey, false);
      final savedAt = c.read(libraryProvider).journeys.single.savedAtMs;

      lib.replaceJourney(oldKey, _swapped());
      await _settle();

      final entry = c.read(libraryProvider).journeys.single;
      expect(entry.key, _saved(_swapped()).key,
          reason: 'the library must track the train actually being taken');
      expect(c.read(libraryProvider).hasJourney(oldKey), isFalse,
          reason: 'the dropped itinerary would keep firing its reminders');
      expect(entry.savedAtMs, savedAt);
      expect(entry.watched, isFalse, reason: 'the bell setting must carry over');
      c.dispose();
    });

    test('replaceJourney ignores a trip that was never saved', () async {
      final c = ProviderContainer();
      final lib = c.read(libraryProvider.notifier);
      await _settle();
      lib.replaceJourney(_saved(_journey()).key, _swapped());
      await _settle();
      expect(c.read(libraryProvider).journeys, isEmpty,
          reason: 'swapping a leg must not silently save the trip');
      c.dispose();
    });

    test('a swap onto an already-saved trip collapses into one entry',
        () async {
      final c = ProviderContainer();
      final lib = c.read(libraryProvider.notifier);
      lib.toggleJourney(_journey());
      lib.toggleJourney(_swapped());
      await _settle();
      expect(c.read(libraryProvider).journeys, hasLength(2));

      lib.replaceJourney(_saved(_journey()).key, _swapped());
      await _settle();

      expect(c.read(libraryProvider).journeys, hasLength(1),
          reason: 'two entries for one trip = every reminder twice');
      c.dispose();
    });

    test('the swap survives a restart', () async {
      final c1 = ProviderContainer();
      c1.read(libraryProvider.notifier).toggleJourney(_journey());
      await _settle();
      c1.read(libraryProvider.notifier)
          .replaceJourney(_saved(_journey()).key, _swapped());
      await _settle();
      c1.dispose();

      final c2 = ProviderContainer();
      c2.read(libraryProvider);
      await _settle();
      expect(c2.read(libraryProvider).journeys.single.key,
          _saved(_swapped()).key);
      c2.dispose();
    });
  });
}
