import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_log.dart';
import '../models/bahnbonus.dart';
import '../services/db_account_service.dart';
import 'account_provider.dart';
import 'service_providers.dart';

/// Everything the BahnBonus screen shows at once (#112).
class BahnbonusOverview {
  final BbLoyalty loyalty;
  final List<BbLevelBorder> levelBorders;
  final List<BbDigitalVoucher> vouchers;
  final List<BbSwapOffer> swapOffers;

  /// True when this came from the disk cache and the live request failed.
  final bool stale;

  const BahnbonusOverview({
    required this.loyalty,
    this.levelBorders = const [],
    this.vouchers = const [],
    this.swapOffers = const [],
    this.stale = false,
  });

  /// The next tier and the status points still missing for it, or null at
  /// Platin / without tier data.
  ({BbLevel level, int missing})? get nextLevel {
    for (final b in levelBorders) {
      if (b.level.index > loyalty.level.index) {
        final missing = b.requiredPoints - loyalty.status.points;
        return (level: b.level, missing: missing < 0 ? 0 : missing);
      }
    }
    return null;
  }
}

/// On-disk copy of member number, points and tiers, so the digital card
/// still works offline at the counter. Vouchers are not cached: a code that
/// was already used must not show as valid.
class BahnbonusLoyaltyCache {
  static const _kKey = 'db_bahnbonus_loyalty_v1';

  static Future<BahnbonusOverview?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw == null || raw.isEmpty) return null;
      final j = json.decode(raw) as Map<String, dynamic>;
      return BahnbonusOverview(
        loyalty: BbLoyalty.fromJson(j['loyalty'] as Map<String, dynamic>),
        levelBorders: BbLevelBorder.listFromJson(j),
        stale: true,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(BahnbonusOverview o) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kKey,
        json.encode({
          'loyalty': o.loyalty.toJson(),
          'levelBorders': o.levelBorders.map((b) => b.toJson()).toList(),
        }),
      );
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kKey);
    } catch (_) {}
  }
}

class BahnbonusOverviewController extends AsyncNotifier<BahnbonusOverview?> {
  bool _needsAuthorization = false;

  /// The one-time BahnBonus link (second OAuth client, same DB login) is
  /// missing. The screen then shows a "Verknüpfen" button.
  bool get needsAuthorization => _needsAuthorization;

  DbAccountService get _service => ref.read(dbAccountServiceProvider);

  @override
  Future<BahnbonusOverview?> build() async {
    final loggedIn = ref.watch(dbAuthProvider.select((s) => s.isLoggedIn));
    if (!loggedIn) {
      _needsAuthorization = false;
      await BahnbonusLoyaltyCache.clear();
      return null;
    }
    if (!await _service.hasBahnBonusAuthorization()) {
      _needsAuthorization = true;
      return null;
    }
    return _load();
  }

  Future<BahnbonusOverview?> _load({bool connect = false}) async {
    try {
      // Loyalty first: with [connect] it may open the authorization, and the
      // other calls must not race a second one.
      final loyalty = await _service.bahnbonusLoyalty(connect: connect);
      _needsAuthorization = false;
      final parts = await Future.wait<Object?>([
        _quiet(_service.bahnbonusLevelBorders, 'program-infos'),
        _quiet(_service.bahnbonusVouchers, 'vouchers'),
        _quiet(_service.bahnbonusSwapOffers, 'swap-offers'),
      ]);
      final overview = BahnbonusOverview(
        loyalty: loyalty,
        levelBorders: (parts[0] as List<BbLevelBorder>?) ?? const [],
        vouchers: (parts[1] as List<BbDigitalVoucher>?) ?? const [],
        swapOffers: (parts[2] as List<BbSwapOffer>?) ?? const [],
      );
      await BahnbonusLoyaltyCache.save(overview);
      return overview;
    } on DbBahnBonusAuthorizationRequired {
      _needsAuthorization = true;
      return null;
    } catch (e) {
      final cached = await BahnbonusLoyaltyCache.load();
      if (cached != null) return cached;
      rethrow;
    }
  }

  /// A side list failing (vouchers, offers) must not hide points and card.
  Future<T?> _quiet<T>(Future<T> Function() f, String what) async {
    try {
      return await f();
    } on DbBahnBonusAuthorizationRequired {
      rethrow;
    } catch (e) {
      AppLog.log('bahnbonus $what failed: $e', tag: 'db-account');
      return null;
    }
  }

  Future<void> refresh() async {
    if (_needsAuthorization) return;
    state = await AsyncValue.guard(_load);
  }

  /// Runs the one-time BahnBonus authorization, then loads everything.
  Future<void> connect() async {
    _needsAuthorization = false;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() => _load(connect: true));
    // CO₂ uses the same token; let it pick the new link up.
    ref.invalidate(bahnbonusCo2Provider);
  }

  /// Spends points on [offer], then reloads points and vouchers.
  Future<void> redeem(BbSwapOffer offer) async {
    await _service.redeemBahnbonusSwapOffer(offer.id);
    await refresh();
  }
}

final bahnbonusOverviewProvider =
    AsyncNotifierProvider<BahnbonusOverviewController, BahnbonusOverview?>(
      BahnbonusOverviewController.new,
    );

/// Paged points history for one [BbPointsType].
class BahnbonusHistory {
  final List<BbTransaction> items;
  final String? after;
  final bool loadingMore;
  const BahnbonusHistory(this.items, this.after, {this.loadingMore = false});
  bool get hasMore => after != null;
}

class BahnbonusHistoryController extends AsyncNotifier<BahnbonusHistory> {
  BahnbonusHistoryController(this.type);
  final BbPointsType type;

  @override
  Future<BahnbonusHistory> build() async {
    final page = await ref
        .read(dbAccountServiceProvider)
        .bahnbonusTransactions(type: type);
    return BahnbonusHistory(page.items, page.after);
  }

  Future<void> loadMore() async {
    final cur = state.value;
    if (cur == null || !cur.hasMore || cur.loadingMore) return;
    state = AsyncData(
      BahnbonusHistory(cur.items, cur.after, loadingMore: true),
    );
    try {
      final page = await ref
          .read(dbAccountServiceProvider)
          .bahnbonusTransactions(type: type, after: cur.after);
      // A cursor that does not move would page forever.
      final next = page.after == cur.after ? null : page.after;
      state = AsyncData(BahnbonusHistory([...cur.items, ...page.items], next));
    } catch (e) {
      AppLog.log('bahnbonus history page failed: $e', tag: 'db-account');
      state = AsyncData(BahnbonusHistory(cur.items, cur.after));
    }
  }
}

final bahnbonusHistoryProvider = AsyncNotifierProvider.autoDispose
    .family<BahnbonusHistoryController, BahnbonusHistory, BbPointsType>(
      BahnbonusHistoryController.new,
    );
