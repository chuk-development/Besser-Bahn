import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_log.dart';
import '../../../core/extensions.dart';
import '../../../models/journey.dart';
import '../../../models/station.dart';
import '../../../models/transfer_profile.dart';
import '../../../providers/journey_search_provider.dart';
import '../../../providers/service_providers.dart';
import '../../../providers/settings_provider.dart';
import '../../../utils/earlier_onward.dart' show isLongDistanceProduct;
import '../../../utils/tight_chain.dart';
import '../../../widgets/ui/message_card.dart';

/// The change time a rider of [p] can do when they want to: 3 min for
/// "Schnell"/"Normal" (the case from the report: both 30-minute waits on
/// Bremen → Kiel were 3-minute changes away from earlier trains), the
/// profile's own minimum for everyone else.
int tightMinutesFor(TransferProfile p) => p.minTransferMinutes ?? 3;

/// Gain under which the card stays away: a few minutes earlier is not worth
/// three rushed changes.
const tightChainMinGainMinutes = 10;

class TightChainQuery {
  final Station start;
  final Station destination;
  final DateTime at;
  final int tightMinutes;
  final bool regionalOnly;

  const TightChainQuery({
    required this.start,
    required this.destination,
    required this.at,
    required this.tightMinutes,
    required this.regionalOnly,
  });

  @override
  bool operator ==(Object other) =>
      other is TightChainQuery &&
      other.start.vendoLocationId == start.vendoLocationId &&
      other.destination.vendoLocationId == destination.vendoLocationId &&
      other.at == at &&
      other.tightMinutes == tightMinutes &&
      other.regionalOnly == regionalOnly;

  @override
  int get hashCode => Object.hash(
    start.vendoLocationId,
    destination.vendoLocationId,
    at,
    tightMinutes,
    regionalOnly,
  );
}

const _regionalCategories = {
  ProductCategory.regional,
  ProductCategory.sbahn,
  ProductCategory.ubahn,
  ProductCategory.tram,
  ProductCategory.bus,
};

/// The tight chain for one query, or null. A few searches, one per change.
final tightChainProvider = FutureProvider.autoDispose
    .family<Journey?, TightChainQuery>((ref, q) async {
      final settings = ref.read(settingsProvider);
      final vendo = ref.read(vendoServiceProvider);
      try {
        return await buildTightChain(
          start: q.start,
          readyAt: q.at,
          tightMinutes: q.tightMinutes,
          search: (from, at) async {
            if (from.vendoLocationId.isEmpty) return const [];
            final res = await vendo.searchJourneys(
              fromLocationId: from.vendoLocationId,
              toLocationId: q.destination.vendoLocationId,
              dateTime: at,
              verkehrsmittel: q.regionalOnly
                  ? ProductCategory.codesFor(_regionalCategories)
                  : null,
              reisende: settings.searchParty.toReisendeJson(),
              deutschlandTicket: settings.hasDeutschlandTicket,
            );
            return res.journeys;
          },
        );
      } catch (e) {
        AppLog.log('tight chain failed: $e', tag: 'trip-detail');
        return null;
      }
    });

/// "Schneller nach Kiel: an 17:22 statt 17:52" — the rest of the journey
/// rebuilt with tight changes from the change after [arriving].
///
/// Shown once per journey (the caller picks the transfer), self-hides when
/// the tight chain does not arrive [tightChainMinGainMinutes] earlier.
class TightChainHint extends ConsumerWidget {
  /// The train the rider arrives on at the change.
  final JourneyLeg arriving;

  /// Live arrival of [arriving].
  final DateTime? arrivingAt;

  /// Where the journey ends.
  final Station destination;

  /// Live arrival of the journey as booked.
  final DateTime? bookedArrival;

  /// The booked legs after [arriving] — decides regional-only.
  final List<JourneyLeg> bookedTail;

  final void Function(Journey chain) onApply;

  const TightChainHint({
    super.key,
    required this.arriving,
    required this.arrivingAt,
    required this.destination,
    required this.bookedArrival,
    required this.bookedTail,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final arr = arrivingAt;
    final booked = bookedArrival;
    if (arr == null || booked == null) return const SizedBox.shrink();
    final start = arriving.destination;
    if (start.vendoLocationId.isEmpty || destination.vendoLocationId.isEmpty) {
      return const SizedBox.shrink();
    }
    final profile = ref.watch(settingsProvider).transferProfile;
    final tight = tightMinutesFor(profile);
    final now = DateTime.now();
    var readyAt = arr.add(Duration(minutes: tight));
    final soonest = now.add(const Duration(minutes: 1));
    if (soonest.isAfter(readyAt)) readyAt = soonest;
    // 5-minute buckets: "now" moves every rebuild, the searches must not.
    const bucketMs = 5 * 60 * 1000;
    final at = DateTime.fromMillisecondsSinceEpoch(
      readyAt.millisecondsSinceEpoch -
          readyAt.millisecondsSinceEpoch % bucketMs,
    );
    final regionalOnly = !bookedTail.any(
      (l) => !l.isWalking && isLongDistanceProduct(l.line?.product),
    );

    final chain = ref
        .watch(
          tightChainProvider(
            TightChainQuery(
              start: start,
              destination: destination,
              at: at,
              tightMinutes: tight,
              regionalOnly: regionalOnly,
            ),
          ),
        )
        .asData
        ?.value;
    if (chain == null) return const SizedBox.shrink();
    final first = chain.legs.firstOrNull;
    final firstDep = first?.departure ?? first?.plannedDeparture;
    // The bucket may start before the rider is there.
    if (firstDep == null || firstDep.isBefore(readyAt)) {
      return const SizedBox.shrink();
    }
    final chainArr = chain.legs.last.arrival ?? chain.legs.last.plannedArrival;
    if (chainArr == null) return const SizedBox.shrink();
    final gain = booked.difference(chainArr).inMinutes;
    if (gain < tightChainMinGainMinutes) return const SizedBox.shrink();

    final trains = chain.legs.where((l) => !l.isWalking).toList();
    final route = trains
        .map((l) {
          final d = l.departure ?? l.plannedDeparture;
          final name = l.line?.name ?? 'Zug';
          return '$name ${d?.hhmm ?? ''}';
        })
        .join(' → ');
    final change = tightestChange(chain);
    final changeText = change == null
        ? null
        : 'Knappster Umstieg: ${change.minutes} min in ${change.station}.';
    final waitHere = firstDep.difference(arr).inMinutes;

    return MessageCard(
      tone: MessageTone.recommendation,
      icon: Icons.bolt_rounded,
      title:
          'Schneller nach ${destination.name}: an ${chainArr.hhmm} '
          'statt ${booked.hhmm} ($gain min früher)',
      body: [
        '$route.',
        'Mit knappen Umstiegen ($tight min) statt DB-Mindestzeit. '
            'Hier nur $waitHere min Umstieg.',
        ?changeText,
        if (!regionalOnly) 'Fernverkehr: nur ohne Zugbindung (Flexpreis).',
      ].join('\n'),
      trailing: TextButton(
        onPressed: () => onApply(chain),
        child: const Text('Nehmen'),
      ),
    );
  }
}
