import 'dart:async';

/// Collapses concurrent identical requests into a single in-flight call.
///
/// The DB `/mob` backend rate-limits per client: two identical GETs fired at
/// the same moment don't just waste a round-trip, they trip a 429 that then
/// answers *every* request for minutes (see `project_vendo_rate_limit`), and
/// each caller silently falls back to its stale disk cache. That is what made a
/// pull-to-refresh look like it did nothing (#31).
///
/// The rule this enforces: **one refresh = one set of requests**. A caller that
/// asks for a resource already in flight joins the running call instead of
/// starting a second one.
///
/// Only safe for idempotent reads — never key a mutation through this, or two
/// deliberate writes would collapse into one.
class RequestCoalescer {
  final Map<String, Future<Object?>> _inFlight = {};

  /// Runs [body], unless a call with the same [key] is already running — then
  /// its result (or error) is shared with this caller instead.
  Future<T> run<T>(String key, Future<T> Function() body) {
    final running = _inFlight[key];
    if (running != null) return running.then((v) => v as T);

    // A Completer (rather than chaining onto body()'s future) keeps the shared
    // future free of derived listeners: an error must reach every joined caller
    // and nothing else, or it surfaces as an unhandled async error.
    final completer = Completer<T>();
    _inFlight[key] = completer.future;
    body().then(
      (value) {
        _inFlight.remove(key);
        completer.complete(value);
      },
      onError: (Object e, StackTrace st) {
        // Released before completing so a caller that retries from its own
        // error handler starts a fresh call rather than joining a dead one.
        _inFlight.remove(key);
        completer.completeError(e, st);
      },
    );
    return completer.future;
  }

  /// How many distinct calls are in flight — for tests and diagnostics.
  int get inFlightCount => _inFlight.length;
}
