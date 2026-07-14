import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/reisende.dart';
import '../models/split_ticket.dart';
import '../models/transfer_profile.dart';

class AppSettings {
  final BahnCardType bahnCard;
  final bool hasDeutschlandTicket;
  final int age;
  final int apiDelayMs;

  /// The "Reisende & Klasse" selection driving the connection search
  /// (passengers, ages, bike/dog, class, BahnCards, Schwerbehindertenausweis).
  /// Seeded from [bahnCard]/[hasDeutschlandTicket] on first run, then edited
  /// per trip from the search form and persisted.
  final SearchParty searchParty;

  /// When true, the in-train Träwelling check-in button checks in immediately
  /// (origin → destination, [trwlVisibility]) without the confirm sheet.
  final bool trwlAutoCheckin;

  /// Default visibility for app check-ins (TrwlVisibility.value: 0=öffentlich,
  /// 1=nicht gelistet, 2=nur Follower, 3=privat, 4=angemeldete). Defaults to
  /// private — check-ins stay between you and Träwelling unless you opt out.
  final int trwlVisibility;

  /// Whether to schedule offline trip reminders ("In 30 Min fährt dein Zug",
  /// boarding & Umstieg pings) for saved upcoming trips.
  final bool remindersEnabled;

  /// Lead time in minutes for the "mach dich bereit" reminder before departure.
  final int reminderLeadMinutes;

  /// Whether to also ping shortly before each connecting train departs.
  final bool transferAlerts;

  /// "Ankunfts-Wecker": ping ~10 Min and ~5 Min before reaching the final
  /// destination so a dozing rider doesn't miss the stop. Scheduled offline
  /// from the saved arrival time, like the departure reminders.
  final bool arrivalAlertEnabled;

  /// Upgrade the 5-Min arrival ping to a loud, looping alarm (alarm volume,
  /// full-screen) that keeps ringing until stopped. Off by default — opt-in,
  /// since it's deliberately hard to sleep through.
  final bool arrivalAlarmSound;

  /// GPS "Ausstiegsalarm": while on board and the app is open, ring the loud
  /// alarm the moment the device enters the destination's radius — delay-proof,
  /// unlike the timetable-based arrival ping. Off by default (uses location).
  final bool exitAlarmEnabled;

  /// How fast this rider changes trains. Scales how tight a transfer is judged
  /// to be, everywhere the app judges one (#11, point 7). Local-only.
  final TransferProfile transferProfile;

  const AppSettings({
    this.bahnCard = BahnCardType.none,
    this.hasDeutschlandTicket = false,
    this.age = 30,
    this.apiDelayMs = 400,
    this.trwlAutoCheckin = false,
    this.trwlVisibility = 3,
    this.remindersEnabled = true,
    this.reminderLeadMinutes = 30,
    this.transferAlerts = true,
    this.arrivalAlertEnabled = true,
    this.arrivalAlarmSound = false,
    this.exitAlarmEnabled = false,
    this.transferProfile = TransferProfile.normal,
    this.searchParty = const SearchParty(),
  });

  AppSettings copyWith({
    BahnCardType? bahnCard,
    bool? hasDeutschlandTicket,
    int? age,
    int? apiDelayMs,
    bool? trwlAutoCheckin,
    int? trwlVisibility,
    bool? remindersEnabled,
    int? reminderLeadMinutes,
    bool? transferAlerts,
    bool? arrivalAlertEnabled,
    bool? arrivalAlarmSound,
    bool? exitAlarmEnabled,
    TransferProfile? transferProfile,
    SearchParty? searchParty,
  }) {
    return AppSettings(
      bahnCard: bahnCard ?? this.bahnCard,
      hasDeutschlandTicket: hasDeutschlandTicket ?? this.hasDeutschlandTicket,
      age: age ?? this.age,
      apiDelayMs: apiDelayMs ?? this.apiDelayMs,
      trwlAutoCheckin: trwlAutoCheckin ?? this.trwlAutoCheckin,
      trwlVisibility: trwlVisibility ?? this.trwlVisibility,
      remindersEnabled: remindersEnabled ?? this.remindersEnabled,
      reminderLeadMinutes: reminderLeadMinutes ?? this.reminderLeadMinutes,
      transferAlerts: transferAlerts ?? this.transferAlerts,
      arrivalAlertEnabled: arrivalAlertEnabled ?? this.arrivalAlertEnabled,
      arrivalAlarmSound: arrivalAlarmSound ?? this.arrivalAlarmSound,
      exitAlarmEnabled: exitAlarmEnabled ?? this.exitAlarmEnabled,
      transferProfile: transferProfile ?? this.transferProfile,
      searchParty: searchParty ?? this.searchParty,
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
    final bahnCard = BahnCardType.values[prefs.getInt('bahnCard') ?? 0];
    final dTicket = prefs.getBool('deutschlandTicket') ?? false;
    state = AppSettings(
      bahnCard: bahnCard,
      hasDeutschlandTicket: dTicket,
      age: prefs.getInt('age') ?? 30,
      apiDelayMs: prefs.getInt('apiDelayMs') ?? 400,
      trwlAutoCheckin: prefs.getBool('trwlAutoCheckin') ?? false,
      trwlVisibility: prefs.getInt('trwlVisibility') ?? 3,
      remindersEnabled: prefs.getBool('remindersEnabled') ?? true,
      reminderLeadMinutes: prefs.getInt('reminderLeadMinutes') ?? 30,
      transferAlerts: prefs.getBool('transferAlerts') ?? true,
      arrivalAlertEnabled: prefs.getBool('arrivalAlertEnabled') ?? true,
      arrivalAlarmSound: prefs.getBool('arrivalAlarmSound') ?? false,
      exitAlarmEnabled: prefs.getBool('exitAlarmEnabled') ?? false,
      transferProfile:
          TransferProfile.fromName(prefs.getString('transferProfile')),
      // First run (no stored party): seed from the single-card settings so the
      // search behaves exactly as before until the user customises the party.
      searchParty: SearchParty.tryDecode(prefs.getString('searchParty')) ??
          SearchParty.fromSettings(bahnCard, dTicket),
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
    await prefs.setBool('remindersEnabled', state.remindersEnabled);
    await prefs.setInt('reminderLeadMinutes', state.reminderLeadMinutes);
    await prefs.setBool('transferAlerts', state.transferAlerts);
    await prefs.setBool('arrivalAlertEnabled', state.arrivalAlertEnabled);
    await prefs.setBool('arrivalAlarmSound', state.arrivalAlarmSound);
    await prefs.setBool('exitAlarmEnabled', state.exitAlarmEnabled);
    await prefs.setString('transferProfile', state.transferProfile.name);
    await prefs.setString('searchParty', state.searchParty.encode());
  }

  void setBahnCard(BahnCardType card) {
    // Setting "my" card also re-seeds the search party to a single adult with
    // that card — the simple settings path mirrors the old behaviour for users
    // who never open the advanced "Reisende" sheet.
    state = state.copyWith(
      bahnCard: card,
      searchParty: SearchParty.fromSettings(card, state.hasDeutschlandTicket),
    );
    _save();
  }

  void setDeutschlandTicket(bool value) {
    state = state.copyWith(
      hasDeutschlandTicket: value,
      searchParty: state.searchParty.copyWith(deutschlandTicket: value),
    );
    _save();
  }

  void setSearchParty(SearchParty party) {
    state = state.copyWith(searchParty: party);
    _save();
  }

  /// Seed search defaults from the signed-in DB account. Called from the auth
  /// notifier on successful profile load so the user doesn't have to re-enter
  /// what DB already knows (age, BahnCard, Deutschland-Ticket). Manual changes
  /// after this stick because the apply happens at most once per login.
  void applyFromDbAccount({
    int? age,
    BahnCardType? card,
    bool? hasDeutschlandTicket,
  }) {
    final newCard = card ?? state.bahnCard;
    final newDTicket = hasDeutschlandTicket ?? state.hasDeutschlandTicket;
    state = state.copyWith(
      age: age ?? state.age,
      bahnCard: newCard,
      hasDeutschlandTicket: newDTicket,
      searchParty: SearchParty.fromSettings(newCard, newDTicket),
    );
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

  void setRemindersEnabled(bool value) {
    state = state.copyWith(remindersEnabled: value);
    _save();
  }

  void setReminderLeadMinutes(int value) {
    state = state.copyWith(reminderLeadMinutes: value);
    _save();
  }

  void setTransferAlerts(bool value) {
    state = state.copyWith(transferAlerts: value);
    _save();
  }

  void setArrivalAlertEnabled(bool value) {
    state = state.copyWith(arrivalAlertEnabled: value);
    _save();
  }

  void setArrivalAlarmSound(bool value) {
    state = state.copyWith(arrivalAlarmSound: value);
    _save();
  }

  void setExitAlarmEnabled(bool value) {
    state = state.copyWith(exitAlarmEnabled: value);
    _save();
  }

  void setTransferProfile(TransferProfile profile) {
    state = state.copyWith(transferProfile: profile);
    _save();
  }
}

final settingsProvider =
    NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
