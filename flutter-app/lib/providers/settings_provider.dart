import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/split_ticket.dart';

class AppSettings {
  final BahnCardType bahnCard;
  final bool hasDeutschlandTicket;
  final int age;
  final int apiDelayMs;

  /// When true, the in-train Träwelling check-in button checks in immediately
  /// (origin → destination, [trwlVisibility]) without the confirm sheet.
  final bool trwlAutoCheckin;

  /// Default visibility for app check-ins (TrwlVisibility.value: 0=öffentlich,
  /// 1=nicht gelistet, 2=nur Follower, 3=privat, 4=angemeldete). Defaults to
  /// private — check-ins stay between you and Träwelling unless you opt out.
  final int trwlVisibility;

  const AppSettings({
    this.bahnCard = BahnCardType.none,
    this.hasDeutschlandTicket = false,
    this.age = 30,
    this.apiDelayMs = 400,
    this.trwlAutoCheckin = false,
    this.trwlVisibility = 3,
  });

  AppSettings copyWith({
    BahnCardType? bahnCard,
    bool? hasDeutschlandTicket,
    int? age,
    int? apiDelayMs,
    bool? trwlAutoCheckin,
    int? trwlVisibility,
  }) {
    return AppSettings(
      bahnCard: bahnCard ?? this.bahnCard,
      hasDeutschlandTicket: hasDeutschlandTicket ?? this.hasDeutschlandTicket,
      age: age ?? this.age,
      apiDelayMs: apiDelayMs ?? this.apiDelayMs,
      trwlAutoCheckin: trwlAutoCheckin ?? this.trwlAutoCheckin,
      trwlVisibility: trwlVisibility ?? this.trwlVisibility,
    );
  }
}

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    _load();
    return const AppSettings();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = AppSettings(
      bahnCard: BahnCardType.values[prefs.getInt('bahnCard') ?? 0],
      hasDeutschlandTicket: prefs.getBool('deutschlandTicket') ?? false,
      age: prefs.getInt('age') ?? 30,
      apiDelayMs: prefs.getInt('apiDelayMs') ?? 400,
      trwlAutoCheckin: prefs.getBool('trwlAutoCheckin') ?? false,
      trwlVisibility: prefs.getInt('trwlVisibility') ?? 3,
    );
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('bahnCard', state.bahnCard.index);
    await prefs.setBool('deutschlandTicket', state.hasDeutschlandTicket);
    await prefs.setInt('age', state.age);
    await prefs.setInt('apiDelayMs', state.apiDelayMs);
    await prefs.setBool('trwlAutoCheckin', state.trwlAutoCheckin);
    await prefs.setInt('trwlVisibility', state.trwlVisibility);
  }

  void setBahnCard(BahnCardType card) {
    state = state.copyWith(bahnCard: card);
    _save();
  }

  void setDeutschlandTicket(bool value) {
    state = state.copyWith(hasDeutschlandTicket: value);
    _save();
  }

  void setAge(int age) {
    state = state.copyWith(age: age);
    _save();
  }

  void setApiDelay(int ms) {
    state = state.copyWith(apiDelayMs: ms);
    _save();
  }

  void setTrwlAutoCheckin(bool value) {
    state = state.copyWith(trwlAutoCheckin: value);
    _save();
  }

  void setTrwlVisibility(int value) {
    state = state.copyWith(trwlVisibility: value);
    _save();
  }
}

final settingsProvider =
    NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
