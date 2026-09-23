import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_log.dart';
import '../models/best_price.dart';
import '../models/station.dart';
import 'journey_search_provider.dart';
import 'service_providers.dart';
import 'settings_provider.dart';

/// What day, and for whom, to price (#21). The party and mode filter ride
/// along so the calendar quotes what the rider would actually pay — a
/// BahnCard 50 holder comparing full fares would be shopping someone else's
/// trip.
class BestPriceRequest {
  final Station from;
  final Station to;
  final DateTime date;

  const BestPriceRequest({
    required this.from,
    required this.to,
    required this.date,
  });

  /// Only the day matters — the endpoint prices the whole day, so two requests
  /// differing by the hour must not be two cache entries.
  DateTime get _day => DateTime(date.year, date.month, date.day);

  @override
  bool operator ==(Object other) =>
      other is BestPriceRequest &&
      other.from.vendoLocationId == from.vendoLocationId &&
      other.to.vendoLocationId == to.vendoLocationId &&
      other._day == _day;

  @override
  int get hashCode =>
      Object.hash(from.vendoLocationId, to.vendoLocationId, _day);
}

/// The day's Bestpreis calendar. One request per day, cached by [ref.keepAlive]
/// for as long as the screen lives — the backend rate-limits hard, and paging
/// back and forth between days would otherwise re-ask for what we have.
final bestPriceProvider = FutureProvider.autoDispose
    .family<BestPriceDay, BestPriceRequest>((ref, req) async {
      final settings = ref.watch(settingsProvider);
      final search = ref.watch(journeySearchProvider);
      final party = settings.searchParty;

      final link = ref.keepAlive();
      ref.onDispose(link.close);

      AppLog.log(
        'best price ${AppLog.pii(req.from.name)} → ${AppLog.pii(req.to.name)} '
        'on ${AppLog.pii(req._day, 'Zeit')}',
        tag: 'bestprice',
      );
      return ref
          .read(vendoServiceProvider)
          .fetchBestPrices(
            fromLocationId: req.from.vendoLocationId,
            toLocationId: req.to.vendoLocationId,
            date: req.date,
            firstClass: party.firstClass,
            reisende: party.toReisendeJson(),
            deutschlandTicket: party.deutschlandTicket,
            verkehrsmittel: ProductCategory.codesFor(search.products),
            nurDeutschlandTicketVerbindungen: search.onlyDeutschlandTicket,
          );
    });
