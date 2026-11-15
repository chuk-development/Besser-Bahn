import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_log.dart';
import '../../../core/extensions.dart';
import '../../../models/journey.dart';
import '../../../providers/journey_search_provider.dart';
import '../../../providers/service_providers.dart';
import '../../../providers/settings_provider.dart';
import '../../../utils/earlier_onward.dart';
import '../../../widgets/ui/message_card.dart';

/// One search: direct, regional-only connections from [fromId] to [toId],
/// leaving from [at] on.
typedef EarlierOnwardQuery = ({String fromId, String toId, DateTime at});

/// The candidates for "Früher weiter". [EarlierOnwardQuery.at] is bucketed to
/// 10 minutes by the caller, so a screen that rebuilds every few seconds
/// with "now" in the ready time asks the backend once per bucket, not once
/// per rebuild.
final earlierOnwardCandidatesProvider = FutureProvider.autoDispose
    .family<List<Journey>, EarlierOnwardQuery>((ref, q) async {
      final settings = ref.read(settingsProvider);
      try {
        final res = await ref
            .read(vendoServiceProvider)
            .searchJourneys(
              fromLocationId: q.fromId,
              toLocationId: q.toId,
              dateTime: q.at,
              maxTransfers: 0,
              // Never long distance: a Sparpreis binds the booked IC/ICE, and
              // the point is to ride what the ticket already covers.
              verkehrsmittel: ProductCategory.codesFor({
                ProductCategory.regional,
                ProductCategory.sbahn,
                ProductCategory.ubahn,
                ProductCategory.tram,
                ProductCategory.bus,
              }),
              reisende: settings.searchParty.toReisendeJson(),
              deutschlandTicket: settings.hasDeutschlandTicket,
            );
        return res.journeys;
      } catch (e) {
        // A hint that can't load is no hint — never an error card.
        AppLog.log('earlier onward search failed: $e', tag: 'trip-detail');
        return const [];
      }
    });

/// "Früher weiter": the rider waits long for [booked] at a change, while an
/// earlier train already goes to where the [following] train leaves.
///
/// Self-hides unless there is a real suggestion. One search per transfer, and
/// only for a wait of [earlierOnwardMinWaitMinutes] or more on a regional leg.
class EarlierOnwardHint extends ConsumerWidget {
  /// The train the rider arrives on.
  final JourneyLeg arriving;

  /// Live arrival of [arriving].
  final DateTime? arrivingAt;

  /// The booked onward train the rider waits for.
  final JourneyLeg booked;

  /// Live departure of [booked].
  final DateTime? bookedDeparture;

  /// The train after [booked], or null when [booked] is the last one.
  final JourneyLeg? following;

  /// Take it: replace the legs between [arriving] and [following].
  final void Function(EarlierOnward onward) onApply;

  const EarlierOnwardHint({
    super.key,
    required this.arriving,
    required this.arrivingAt,
    required this.booked,
    required this.bookedDeparture,
    required this.following,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final arr = arrivingAt;
    final dep = bookedDeparture;
    if (arr == null || dep == null) return const SizedBox.shrink();
    if (isLongDistanceProduct(booked.line?.product)) {
      return const SizedBox.shrink();
    }
    if (dep.difference(arr).inMinutes < earlierOnwardMinWaitMinutes) {
      return const SizedBox.shrink();
    }
    final now = DateTime.now();
    // Nothing to gain any more: the booked train leaves soon or has left.
    if (dep.difference(now).inMinutes < earlierOnwardMinGainMinutes) {
      return const SizedBox.shrink();
    }
    final from = arriving.destination;
    final to = following?.origin ?? booked.destination;
    if (from.vendoLocationId.isEmpty || to.vendoLocationId.isEmpty) {
      return const SizedBox.shrink();
    }

    final profile = ref.watch(settingsProvider).transferProfile;
    final buffer = (profile.minTransferMinutes ?? 0) < 5
        ? 5
        : profile.minTransferMinutes!;
    var readyAt = arr.add(Duration(minutes: buffer));
    // Already standing at the change: from now on, not from the arrival.
    final soonest = now.add(const Duration(minutes: 2));
    if (soonest.isAfter(readyAt)) readyAt = soonest;

    final bucket = DateTime.fromMillisecondsSinceEpoch(
      readyAt.millisecondsSinceEpoch -
          readyAt.millisecondsSinceEpoch %
              const Duration(minutes: 10).inMilliseconds,
    );
    final candidates = ref
        .watch(
          earlierOnwardCandidatesProvider((
            fromId: from.vendoLocationId,
            toId: to.vendoLocationId,
            at: bucket,
          )),
        )
        .asData
        ?.value;
    if (candidates == null || candidates.isEmpty) {
      return const SizedBox.shrink();
    }

    final pick = earlierOnwardFor(
      candidates: candidates,
      booked: booked,
      readyAt: readyAt,
      following: following,
      bufferMinutes: buffer,
    );
    if (pick == null) return const SizedBox.shrink();

    final t = pick.train;
    final tDep = t.departure ?? t.plannedDeparture;
    final tArr =
        pick.journey.legs.last.arrival ?? pick.journey.legs.last.plannedArrival;
    final name = t.line?.name.isNotEmpty == true ? t.line!.name : 'Zug';
    final gleis = t.departurePlatform;
    final bookedName = booked.line?.name ?? 'gebuchter Zug';
    final first =
        '$name ${tDep?.hhmm ?? ''}${gleis != null ? ' (Gl. $gleis)' : ''} '
        'statt $bookedName ${dep.hhmm}'
        '${tArr != null ? ' · an ${tArr.hhmm}' : ''}.';
    final String second;
    final wait = pick.waitThereMinutes;
    if (following != null && wait != null) {
      final followName = following!.line?.name ?? 'Anschluss';
      second =
          'Du wartest dann $wait min in ${to.name} auf $followName '
          'statt hier. Anschluss bleibt gleich.';
    } else {
      second = 'Du bist ${pick.gainMinutes} min früher da.';
    }

    return MessageCard(
      tone: MessageTone.recommendation,
      icon: Icons.fast_forward_rounded,
      title: 'Früher weiter nach ${to.name}',
      body: '$first\n$second',
      trailing: TextButton(
        onPressed: () => onApply(pick),
        child: const Text('Nehmen'),
      ),
    );
  }
}
