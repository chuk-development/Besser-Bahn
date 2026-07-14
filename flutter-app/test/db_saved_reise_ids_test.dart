import 'package:besser_bahn/providers/account_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lets _restore()'s SharedPreferences read settle before asserting.
Future<void> _settle() => Future.delayed(const Duration(milliseconds: 10));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('DbSavedReiseIds — key→rkUuid map (#15)', () {
    test('a mapping survives a restart', () async {
      final c1 = ProviderContainer();
      c1.read(dbSavedReiseIdsProvider.notifier).put('KEY_A', 'uuid-a');
      await _settle();
      c1.dispose();

      // A fresh container = a cold start.
      final c2 = ProviderContainer();
      c2.read(dbSavedReiseIdsProvider);
      await _settle();

      expect(c2.read(dbSavedReiseIdsProvider)['KEY_A'], 'uuid-a',
          reason: 'without this, un-bookmarking after a restart silently '
              'leaves the DB trip behind');
      c2.dispose();
    });

    test('take() removes the mapping and it stays gone across a restart',
        () async {
      final c1 = ProviderContainer();
      c1.read(dbSavedReiseIdsProvider.notifier).put('KEY_A', 'uuid-a');
      await _settle();
      expect(c1.read(dbSavedReiseIdsProvider.notifier).take('KEY_A'), 'uuid-a');
      await _settle();
      c1.dispose();

      final c2 = ProviderContainer();
      c2.read(dbSavedReiseIdsProvider);
      await _settle();
      expect(c2.read(dbSavedReiseIdsProvider), isEmpty);
      c2.dispose();
    });

    test('take() on an unknown key returns null', () async {
      final c = ProviderContainer();
      expect(c.read(dbSavedReiseIdsProvider.notifier).take('NOPE'), isNull);
      c.dispose();
    });

    test('register() learns a DB trip this session did not create', () async {
      final c = ProviderContainer();
      final n = c.read(dbSavedReiseIdsProvider.notifier);
      // What reconciliation does after reading the DB's own saved trips.
      n.register('KEY_REMOTE', 'uuid-remote');
      await _settle();

      expect(n.lookup('KEY_REMOTE'), 'uuid-remote');
      c.dispose();
    });

    test('register() is idempotent — safe to call on every tile render',
        () async {
      final c = ProviderContainer();
      final n = c.read(dbSavedReiseIdsProvider.notifier);
      n.register('KEY_A', 'uuid-a');
      await _settle();
      final before = c.read(dbSavedReiseIdsProvider);
      n.register('KEY_A', 'uuid-a');
      expect(identical(before, c.read(dbSavedReiseIdsProvider)), isTrue,
          reason: 're-registering the same pair must not rebuild watchers');
      c.dispose();
    });

    test('restore does not clobber a mapping registered while it was in flight',
        () async {
      SharedPreferences.setMockInitialValues(
          {'db_saved_reise_ids_v1': '{"KEY_OLD":"uuid-old"}'});
      final c = ProviderContainer();
      // Registering immediately races _restore()'s async read.
      c.read(dbSavedReiseIdsProvider.notifier).register('KEY_NEW', 'uuid-new');
      await _settle();

      final state = c.read(dbSavedReiseIdsProvider);
      expect(state['KEY_NEW'], 'uuid-new', reason: 'the live write must win');
      expect(state['KEY_OLD'], 'uuid-old', reason: 'and the disk one survives');
      c.dispose();
    });

    test('clear() beats an in-flight restore (logout must not resurrect)',
        () async {
      SharedPreferences.setMockInitialValues(
          {'db_saved_reise_ids_v1': '{"KEY_OLD":"uuid-old"}'});
      final c = ProviderContainer();
      // Logging out the instant the app starts, while _restore() is reading.
      await c.read(dbSavedReiseIdsProvider.notifier).clear();
      await _settle();

      expect(c.read(dbSavedReiseIdsProvider), isEmpty,
          reason: "a restore in flight must not merge the signed-out "
              "account's trips back in");
      c.dispose();
    });

    test('clear() empties the map and the disk copy (logout)', () async {
      final c1 = ProviderContainer();
      c1.read(dbSavedReiseIdsProvider.notifier).put('KEY_A', 'uuid-a');
      await _settle();
      await c1.read(dbSavedReiseIdsProvider.notifier).clear();
      expect(c1.read(dbSavedReiseIdsProvider), isEmpty);
      c1.dispose();

      final c2 = ProviderContainer();
      c2.read(dbSavedReiseIdsProvider);
      await _settle();
      expect(c2.read(dbSavedReiseIdsProvider), isEmpty,
          reason: "a signed-out account's trips must not linger on disk");
      c2.dispose();
    });
  });
}
