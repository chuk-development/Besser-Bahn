import '../core/app_log.dart';
import '../models/journey.dart';
import '../models/station.dart';
import '../models/transfer_profile.dart';
import '../utils/earlier_alight.dart';
import 'vendo_service.dart';

/// What a rescue-option-B run found (#26).
class EarlierAlightResult {
  /// The do-nothing baseline: ride on, miss the connection, take the next
  /// train from the planned change station. Null when even that couldn't be
  /// searched — then nothing can be compared and [options] is empty.
  final Journey? fallback;

  /// Suggestions that genuinely beat [fallback], best first. Empty is a real
  /// answer — getting off early doesn't always help — but ONLY when
  /// [complete]. See there.
  final List<EarlierAlightOption> options;

  /// Every stop we meant to search was actually searched.
  ///
  /// False means a request failed (in practice: the rate limit) and the
  /// fan-out stopped early, so an empty [options] proves nothing. The
  /// difference matters to the rider: "we looked, riding on is genuinely best"
  /// and "we couldn't look" are opposite advice, and showing the first when
  /// the second is true talks someone out of a rescue that may well exist.
  final bool complete;

  const EarlierAlightResult({
    this.fallback,
    this.options = const [],
    this.complete = true,
  });

  /// Nothing to offer, and we know it.
  static const empty = EarlierAlightResult();

  /// We couldn't find out.
  static const failed = EarlierAlightResult(complete: false);
}

/// Finds "get off earlier and go another way" rescues for a transfer that's
/// about to break.
///
/// Every judgement lives in `utils/earlier_alight.dart`; this class only does
/// the part that needs a network: one search per candidate stop, plus one for
/// the baseline.
///
/// Request budget is the whole design constraint. The /mob backend rate-limits
/// per client and answers a burst with ~4 minutes of solid 429s while its
/// `Retry-After` lies about it (see `project_vendo_rate_limit`), and a 429
/// would take out the rest of the screen's live data too. Hence: at most
/// [maxCandidates] + 1 requests, strictly serial, paced by the user's own
/// `apiDelayMs`, and every answer cached — the connection screen rebuilds this
/// on each live refresh, and a delay changing by a minute must not re-run the
/// whole fan-out.
class EarlierAlightService {
  EarlierAlightService(this._vendo);

  final VendoService _vendo;

  /// Searches are keyed by from/to/minute, so the repeated calls a live
  /// refresh triggers cost nothing. Kept per service instance, which is an
  /// app-lifetime provider.
  final _cache = <String, List<Journey>>{};

  /// How long a cached search stays trustworthy. Long enough to survive the
  /// screen's refresh cycle, short enough that a suggestion can't go stale
  /// while the rider is still deciding.
  static const cacheTtl = Duration(minutes: 3);
  final _cachedAt = <String, DateTime>{};

  /// Hard ceiling on searched stops, on top of the pure picker's own cap.
  static const maxCandidates = 4;

  /// Fan-outs never overlap, app-wide. A badly delayed journey can have two
  /// at-risk transfers, and both leg sections load themselves the moment they
  /// build — two parallel fan-outs are ~10 requests in a couple of seconds,
  /// which is squarely inside what trips the /mob limit for minutes. Chaining
  /// them costs a few seconds on a rare case and also lets the second run hit
  /// the first one's cache.
  Future<void> _queue = Future.value();

  Future<EarlierAlightResult> findOptions({
    /// The train being ridden — the one to get off early.
    required JourneyLeg currentLeg,

    /// The connection at risk (only its trip id is needed: it's the train the
    /// baseline must NOT be allowed to use).
    required JourneyLeg onwardLeg,

    /// The journey as booked — decides the ticket note.
    required Journey original,

    /// Where the rider is actually going.
    required Station destination,

    /// The ridden train's stops with live times ([alightStopsOfLeg]).
    required List<AlightStop> stops,

    /// When the delayed train really puts the rider at the change station.
    required DateTime readyAt,
    required TransferProfile profile,
    required bool hasDeutschlandTicket,
    required List<Map<String, dynamic>> reisende,
    required bool firstClass,
    required int apiDelayMs,
    DateTime? now,
  }) {
    final run = _queue.then((_) => _findOptions(
          currentLeg: currentLeg,
          onwardLeg: onwardLeg,
          original: original,
          destination: destination,
          stops: stops,
          readyAt: readyAt,
          profile: profile,
          hasDeutschlandTicket: hasDeutschlandTicket,
          reisende: reisende,
          firstClass: firstClass,
          apiDelayMs: apiDelayMs,
          now: now,
        ));
    // The queue must survive a failed run, or one error deadlocks every later
    // caller on a Future that never completes.
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<EarlierAlightResult> _findOptions({
    required JourneyLeg currentLeg,
    required JourneyLeg onwardLeg,
    required Journey original,
    required Station destination,
    required List<AlightStop> stops,
    required DateTime readyAt,
    required TransferProfile profile,
    required bool hasDeutschlandTicket,
    required List<Map<String, dynamic>> reisende,
    required bool firstClass,
    required int apiDelayMs,
    DateTime? now,
  }) async {
    final changeStation = currentLeg.destination;
    final toId = destination.vendoLocationId;
    if (toId.isEmpty || changeStation.vendoLocationId.isEmpty) {
      return EarlierAlightResult.empty;
    }

    final candidates = pickEarlierAlightStops(
      stops: stops,
      now: now ?? DateTime.now(),
      cap: maxCandidates,
    );
    // Nothing reachable to get off at → don't even spend the baseline request.
    if (candidates.isEmpty) return EarlierAlightResult.empty;

    Future<List<Journey>?> search(String fromId, DateTime at) =>
        _search(
          fromId: fromId,
          toId: toId,
          at: at,
          reisende: reisende,
          firstClass: firstClass,
          hasDeutschlandTicket: hasDeutschlandTicket,
          apiDelayMs: apiDelayMs,
        );

    // The baseline first: without it there's no "earlier than what?" and the
    // issue's whole filter ("nur was früher am Ziel ist") can't be applied.
    final baseline = await search(changeStation.vendoLocationId, readyAt);
    if (baseline == null) return EarlierAlightResult.failed;
    final fallback = pickFallbackJourney(
      journeys: baseline,
      readyAt: readyAt,
      plannedOnwardTripId: onwardLeg.tripId,
    );
    final fallbackArrival = fallback?.arrival;
    if (fallbackArrival == null) {
      AppLog.log('no fallback from ${changeStation.name} — nothing to beat',
          tag: 'alight');
      return EarlierAlightResult.empty;
    }

    final options = <EarlierAlightOption>[];
    var complete = true;
    for (final stop in candidates) {
      final arr = stop.arrival;
      final fromId = stop.station.vendoLocationId;
      if (arr == null || fromId.isEmpty) continue;
      final journeys = await search(fromId, arr);
      // The request itself failed — almost always the rate limit. Carrying on
      // through the remaining stops would fire more requests at a backend
      // that just told us to stop, and turn a 4-minute block into a longer
      // one for the whole app. Show what we have, and admit it's partial.
      if (journeys == null) {
        AppLog.log('aborting fan-out after a failed search', tag: 'alight');
        complete = false;
        break;
      }
      // Only the earliest arrival per stop can win — the rest are strictly
      // worse from the same platform, so they'd only pad the list.
      EarlierAlightOption? best;
      for (final j in journeys) {
        final o = evaluateAlightCandidate(
          stop: stop,
          onward: j,
          original: original,
          fallbackArrival: fallbackArrival,
          profile: profile,
          hasDeutschlandTicket: hasDeutschlandTicket,
          currentTripId: currentLeg.tripId,
        );
        if (o == null) continue;
        if (best == null || o.arrival.isBefore(best.arrival)) best = o;
      }
      if (best != null) options.add(best);
    }

    AppLog.log(
        'earlier-alight: ${candidates.length} stops searched, '
        '${options.length} beat the fallback (an ${fallbackArrival.toLocal()})',
        tag: 'alight');
    return EarlierAlightResult(
      fallback: fallback,
      options: rankEarlierAlightOptions(options),
      complete: complete,
    );
  }

  /// One search, cached. Null means the REQUEST failed (as opposed to an empty
  /// list, which is a real "nothing runs here") — the caller must be able to
  /// tell those apart to know whether it's worth asking again.
  Future<List<Journey>?> _search({
    required String fromId,
    required String toId,
    required DateTime at,
    required List<Map<String, dynamic>> reisende,
    required bool firstClass,
    required bool hasDeutschlandTicket,
    required int apiDelayMs,
  }) async {
    // Minute granularity: a live delay ticking over by seconds must not miss
    // the cache and fire the whole fan-out again.
    final key = '$fromId|$toId|${at.toUtc().toIso8601String().substring(0, 16)}'
        '|$firstClass';
    final at0 = _cachedAt[key];
    if (at0 != null && DateTime.now().difference(at0) < cacheTtl) {
      return _cache[key] ?? const [];
    }
    // Paced, never parallel: this is the setting the user turned down exactly
    // to stay under the backend's limit.
    await Future.delayed(Duration(milliseconds: apiDelayMs));
    try {
      final res = await _vendo.searchJourneys(
        fromLocationId: fromId,
        toLocationId: toId,
        dateTime: at,
        reisende: reisende,
        firstClass: firstClass,
        deutschlandTicket: hasDeutschlandTicket,
      );
      _cache[key] = res.journeys;
      _cachedAt[key] = DateTime.now();
      return res.journeys;
    } catch (e) {
      // A 429 is never proof anything changed — it means we asked too fast.
      // Deliberately NOT cached: a retry later is allowed to succeed.
      AppLog.log('earlier-alight search failed ($fromId → $toId): $e',
          tag: 'alight');
      return null;
    }
  }
}
