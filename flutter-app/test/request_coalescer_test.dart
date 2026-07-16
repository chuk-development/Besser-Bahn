import 'dart:async';

import 'package:besser_bahn/core/request_coalescer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RequestCoalescer — one refresh = one set of requests (#31)', () {
    test('concurrent calls with the same key share a single run', () async {
      final c = RequestCoalescer();
      var runs = 0;
      final gate = Completer<String>();
      Future<String> body() {
        runs++;
        return gate.future;
      }

      final a = c.run('k', body);
      final b = c.run('k', body);
      expect(runs, 1, reason: 'the second caller must join, not re-request');
      expect(c.inFlightCount, 1);

      gate.complete('value');
      expect(await a, 'value');
      expect(await b, 'value');
      expect(runs, 1);
    });

    test('the key is released once done, so a later call really re-fetches',
        () async {
      final c = RequestCoalescer();
      var runs = 0;
      Future<int> body() async => ++runs;

      expect(await c.run('k', body), 1);
      expect(c.inFlightCount, 0, reason: 'a finished call must not linger');
      expect(await c.run('k', body), 2,
          reason: 'coalescing is not caching — a fresh pull must hit the wire');
    });

    test('different keys never merge', () async {
      final c = RequestCoalescer();
      final gate = Completer<String>();
      var runs = 0;
      final a = c.run('a', () {
        runs++;
        return gate.future;
      });
      final b = c.run('b', () {
        runs++;
        return gate.future;
      });
      expect(runs, 2);
      expect(c.inFlightCount, 2);
      gate.complete('v');
      await Future.wait([a, b]);
    });

    test('an error reaches every joined caller and frees the key', () async {
      final c = RequestCoalescer();
      var runs = 0;
      final gate = Completer<String>();
      Future<String> failing() {
        runs++;
        return gate.future;
      }

      // Listeners attach before the failure lands, exactly as a real caller's
      // `await` does — otherwise the test itself would orphan the error.
      final a = expectLater(c.run('k', failing), throwsStateError);
      final b = expectLater(c.run('k', failing), throwsStateError,
          reason: 'a joined caller must see the failure, not hang');
      gate.completeError(StateError('boom'));

      await a;
      await b;
      expect(runs, 1);
      expect(c.inFlightCount, 0);

      // A retry after a failure must not join the dead call.
      expect(await c.run('k', () async => 'ok'), 'ok');
    });

    test('a synchronous throw inside the body is delivered as an error',
        () async {
      final c = RequestCoalescer();
      await expectLater(
        c.run<String>('k', () => Future<String>.error(ArgumentError('x'))),
        throwsArgumentError,
      );
      expect(c.inFlightCount, 0);
    });
  });
}
