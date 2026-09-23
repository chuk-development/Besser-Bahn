import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/backup.dart';
import '../../core/constants.dart';
import '../../core/offline_package.dart';
import '../../models/reisende.dart';
import '../../models/split_ticket.dart';
import '../../models/transfer_profile.dart';
import '../../models/traewelling_models.dart';
import '../../providers/offline_package_provider.dart';
import '../../providers/service_providers.dart';
import '../../providers/settings_provider.dart';
import '../../providers/traewelling_provider.dart';
import '../../services/backup_service.dart';
import '../../services/notification_service.dart';
import '../../services/update_check_service.dart';
import '../../widgets/traewelling_logo.dart';
import '../../widgets/update_banner.dart';
import '../../widgets/app_nav_bar.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Einstellungen')),
      body: ListView(
        padding: EdgeInsets.only(bottom: 32 + AppNavBar.insetOf(context)),
        children: [
          // App info
          Card(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.train,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppConstants.appName,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Version ${AppConstants.appVersion}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const UpdateBanner(),

          _sectionHeader(context, 'Benachrichtigungen'),

          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.notifications_active_outlined),
                  title: const Text('Reise-Erinnerungen'),
                  subtitle: const Text(
                    'Vor Abfahrt & Umstieg erinnern — offline geplant, '
                    'für deine gespeicherten Reisen.',
                  ),
                  value: settings.remindersEnabled,
                  onChanged: (v) {
                    notifier.setRemindersEnabled(v);
                    if (v) NotificationService.requestPermissions();
                  },
                ),
                if (settings.remindersEnabled) ...[
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.timer_outlined),
                    title: const Text('Vorlaufzeit'),
                    subtitle: const Text('Wie früh vor Abfahrt erinnern'),
                    trailing: DropdownButton<int>(
                      value: settings.reminderLeadMinutes,
                      underline: const SizedBox.shrink(),
                      items: const [10, 15, 20, 30, 45, 60]
                          .map(
                            (m) => DropdownMenuItem(
                              value: m,
                              child: Text('$m Min'),
                            ),
                          )
                          .toList(),
                      onChanged: (m) {
                        if (m != null) notifier.setReminderLeadMinutes(m);
                      },
                    ),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    secondary: const Icon(Icons.transfer_within_a_station),
                    title: const Text('Umstiegs-Hinweise'),
                    subtitle: const Text(
                      'Kurz bevor dein Anschluss abfährt — mit Gleis & Übergang.',
                    ),
                    value: settings.transferAlerts,
                    onChanged: (v) => notifier.setTransferAlerts(v),
                  ),
                ],
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.pin_drop_outlined),
                  title: const Text('Ankunfts-Wecker'),
                  subtitle: const Text(
                    '10 Min und 5 Min vor Ankunft erinnern (vibriert) — '
                    'damit du deinen Halt nicht verschläfst.',
                  ),
                  value: settings.arrivalAlertEnabled,
                  onChanged: (v) {
                    notifier.setArrivalAlertEnabled(v);
                    if (v) NotificationService.requestPermissions();
                  },
                ),
                if (settings.arrivalAlertEnabled ||
                    settings.exitAlarmEnabled) ...[
                  const Divider(height: 1),
                  SwitchListTile(
                    secondary: const Icon(Icons.alarm),
                    title: const Text('Laut klingeln'),
                    subtitle: const Text(
                      'Ankunfts- und GPS-Hinweis als echten Wecker klingeln '
                      'lassen, bis du ihn stoppst.',
                    ),
                    value: settings.arrivalAlarmSound,
                    onChanged: (v) {
                      notifier.setArrivalAlarmSound(v);
                      if (v) NotificationService.requestPermissions();
                    },
                  ),
                ],
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.my_location),
                  title: const Text('GPS-Ausstiegsalarm'),
                  subtitle: const Text(
                    'Läuft im Hintergrund: warnt am Ziel und erkennt per '
                    'Fahrplan + Position mögliche ungemeldete Verspätung.',
                  ),
                  value: settings.exitAlarmEnabled,
                  onChanged: (v) async {
                    if (!v) {
                      notifier.setExitAlarmEnabled(false);
                      return;
                    }
                    try {
                      await ref
                          .read(locationServiceProvider)
                          .ensureBackgroundPermission();
                      // Both permissions must hold BEFORE we enable: an exit
                      // alarm that can't post a notification would just burn
                      // background GPS with no way to warn the rider.
                      final canNotify =
                          await NotificationService.requestPermissions();
                      if (!canNotify) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Ohne Benachrichtigungen kann der Ausstiegsalarm '
                              'dich nicht warnen — bitte in den Systemeinstellungen '
                              'erlauben.',
                            ),
                          ),
                        );
                        return;
                      }
                      notifier.setExitAlarmEnabled(true);
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text(e.toString())));
                    }
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.tag),
                  title: const Text('Live-Chip: Stationen statt Zeit'),
                  subtitle: const Text(
                    'Der kleine Status-Indikator (auch Samsung Now Bar) zeigt '
                    'die Anzahl Halte bis zum Ausstieg statt der Restzeit.',
                  ),
                  value: settings.liveChipStops,
                  onChanged: (v) => notifier.setLiveChipStops(v),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.directions_walk),
                  title: const Text('Umsteigeprofil'),
                  subtitle: Text(
                    '${settings.transferProfile.emoji} '
                    '${settings.transferProfile.label} — '
                    '${settings.transferProfile.hint}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _pickTransferProfile(context, ref, settings),
                ),
              ],
            ),
          ),

          _sectionHeader(context, 'Träwelling'),

          // Träwelling login/account — moved here from the tab AppBars so it
          // lives in one place: log in/out and reach the hub from Settings.
          Builder(
            builder: (context) {
              final auth = ref.watch(traewellingAuthProvider);
              final user = auth.user;
              final loggedIn = user != null;
              final hasPic = user?.profilePicture?.isNotEmpty ?? false;
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    ListTile(
                      leading: hasPic
                          ? CircleAvatar(
                              radius: 16,
                              backgroundImage: NetworkImage(
                                user!.profilePicture!,
                              ),
                            )
                          // Official Träwelling logo when not signed in.
                          : const TraewellingLogo(size: 32),
                      title: Text(loggedIn ? user.displayName : 'Träwelling'),
                      subtitle: Text(
                        loggedIn
                            ? '@${user.username} · angemeldet'
                            : 'Nicht angemeldet · zum Einloggen tippen',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.push('/trawelling'),
                    ),
                    // Check-in preferences only make sense once connected.
                    if (loggedIn) ...[
                      const Divider(height: 1),
                      SwitchListTile(
                        secondary: const Icon(Icons.bolt),
                        title: const Text('Automatisch einchecken'),
                        subtitle: const Text(
                          'Ein Tipp auf das Träwelling-Symbol im Zug checkt '
                          'sofort ein – ohne Nachfrage.',
                        ),
                        value: settings.trwlAutoCheckin,
                        onChanged: notifier.setTrwlAutoCheckin,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.visibility_outlined),
                        title: const Text('Sichtbarkeit'),
                        subtitle: const Text('Standard für App-Check-ins'),
                        trailing: DropdownButton<int>(
                          value: settings.trwlVisibility,
                          underline: const SizedBox(),
                          onChanged: (v) => notifier.setTrwlVisibility(v!),
                          items: TrwlVisibility.values
                              .map(
                                (v) => DropdownMenuItem(
                                  value: v.value,
                                  child: Text(
                                    v.label,
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),

          _sectionHeader(context, 'Profil'),

          // BahnCard
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.credit_card),
                  title: const Text('BahnCard'),
                  trailing: DropdownButton<BahnCardType>(
                    value: settings.bahnCard,
                    underline: const SizedBox(),
                    onChanged: (v) => notifier.setBahnCard(v!),
                    items: BahnCardType.values.map((bc) {
                      return DropdownMenuItem(
                        value: bc,
                        child: Text(
                          bc.label,
                          style: const TextStyle(fontSize: 14),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const Divider(height: 1),

                // Weitere Ermäßigungen (Halbtax, Vorteilscard, etc.)
                Builder(
                  builder: (context) {
                    final primaryTraveler = settings.searchParty.travelers
                        .firstWhere(
                          (t) => t.typ.isPerson,
                          orElse: () =>
                              const Traveler(typ: TravelerType.erwachsener),
                        );
                    return ListTile(
                      leading: const Icon(Icons.discount_outlined),
                      title: const Text('Weitere Ermäßigung'),
                      subtitle: const Text('Halbtax, Vorteilscard, NL-40 etc.'),
                      trailing: DropdownButton<Reduction>(
                        value: primaryTraveler.weitere,
                        underline: const SizedBox(),
                        onChanged: (v) {
                          if (v != null) {
                            notifier.setWeitereReduction(v);
                          }
                        },
                        items: Reduction.weitereOptions.map((r) {
                          return DropdownMenuItem(
                            value: r,
                            child: Text(
                              r.label,
                              style: const TextStyle(fontSize: 14),
                            ),
                          );
                        }).toList(),
                      ),
                    );
                  },
                ),
                const Divider(height: 1),

                // Deutschland-Ticket
                SwitchListTile(
                  secondary: const Icon(Icons.confirmation_number),
                  title: const Text('Deutschland-Ticket'),
                  subtitle: const Text('Nahverkehr automatisch abziehen'),
                  value: settings.hasDeutschlandTicket,
                  onChanged: notifier.setDeutschlandTicket,
                ),
              ],
            ),
          ),

          _sectionHeader(context, 'Barrierefreiheit'),

          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: SwitchListTile(
              secondary: const Icon(Icons.subject),
              title: const Text('Einfache Sprache'),
              subtitle: const Text(
                'Störungshinweise in einfacheren Worten anzeigen',
              ),
              value: settings.plainLanguage,
              onChanged: (v) => notifier.setPlainLanguage(v),
            ),
          ),

          _sectionHeader(context, 'Offline'),

          const _OfflineStorageCard(),

          _sectionHeader(context, 'Erweitert'),

          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.speed),
                  title: const Text('API-Verzögerung'),
                  subtitle: Text('${settings.apiDelayMs}ms zwischen Anfragen'),
                  trailing: SizedBox(
                    width: 150,
                    child: Slider(
                      value: settings.apiDelayMs.toDouble(),
                      min: 100,
                      max: 2000,
                      divisions: 19,
                      label: '${settings.apiDelayMs}ms',
                      onChanged: (v) => notifier.setApiDelay(v.round()),
                    ),
                  ),
                ),
              ],
            ),
          ),

          _sectionHeader(context, 'Sicherung'),

          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: const Text('Verschlüsselte Sicherung erstellen'),
                  subtitle: const Text(
                    'Bibliothek, Statistik und Einstellungen in eine Datei — '
                    'mit Passwort, nur von dir lesbar. Ohne Konto, ohne Server.',
                  ),
                  onTap: () => _createBackup(context),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.settings_backup_restore),
                  title: const Text('Sicherung einspielen'),
                  subtitle: const Text(
                    'Auf einem neuen Gerät: Datei wählen, Passwort eingeben. '
                    'Zugänge zum DB-Konto sind nie Teil der Sicherung.',
                  ),
                  onTap: () => _restoreBackup(context),
                ),
              ],
            ),
          ),

          _sectionHeader(context, 'Datenschutz'),

          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.shield_outlined),
                  title: Text('Keine Daten an Dritte'),
                  subtitle: Text(
                    'Kein Firebase, kein Google Analytics, kein Tracking. '
                    'Alle Daten bleiben auf deinem Gerät.',
                  ),
                ),
                const Divider(height: 1),
                const ListTile(
                  leading: Icon(Icons.storage_outlined),
                  title: Text('Hosting'),
                  subtitle: Text(
                    'Backend auf Hetzner Deutschland (DSGVO-konform)',
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('Datenschutzerklärung'),
                  trailing: const Icon(Icons.open_in_new, size: 18),
                  onTap: () => _openUrl(
                    context,
                    'https://github.com/chuk-development/Besser-Bahn/'
                    'blob/main/PRIVACY-POLICY.md',
                  ),
                ),
              ],
            ),
          ),

          _sectionHeader(context, 'Über'),

          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.code),
                  title: const Text('Open Source'),
                  subtitle: const Text('Quellcode auf GitHub'),
                  trailing: const Icon(Icons.open_in_new, size: 18),
                  onTap: () => _openUrl(
                    context,
                    'https://github.com/chuk-development/Besser-Bahn',
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.system_update_outlined),
                  title: const Text('Nach Updates suchen'),
                  subtitle: const Text(
                    'Fragt einmal am Tag bei GitHub nach einer neueren '
                    'Version. Es wird nichts über dich übertragen.',
                  ),
                  value: settings.updateCheckEnabled,
                  onChanged: (v) {
                    notifier.setUpdateCheckEnabled(v);
                    if (v) UpdateCheckService.check(force: true);
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.favorite_outline),
                  title: const Text('Feedback'),
                  subtitle: const Text('Bugs melden oder Features vorschlagen'),
                  trailing: const Icon(Icons.open_in_new, size: 18),
                  onTap: () => _openUrl(
                    context,
                    'https://github.com/chuk-development/Besser-Bahn/issues',
                  ),
                ),
              ],
            ),
          ),

          _sectionHeader(context, 'Entwickler'),

          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.bug_report_outlined),
                  title: const Text('Debug-Log'),
                  subtitle: const Text('Live-API-Aufrufe (vendo / bahn.de)'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/debug-log'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.system_update_outlined),
                  title: const Text('Update-Hinweis jetzt prüfen'),
                  subtitle: const Text(
                    'Fragt GitHub sofort. Langes Drücken zeigt den Hinweis '
                    'mit einer erfundenen Version, um ihn anzusehen.',
                  ),
                  onTap: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    await UpdateCheckService.check(force: true);
                    final info = UpdateCheckService.available.value;
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                          info == null
                              ? 'Kein Update: ${AppConstants.appVersion} ist '
                                    'die neueste Version.'
                              : 'Version ${info.latestVersion} verfügbar.',
                        ),
                      ),
                    );
                  },
                  onLongPress: () =>
                      UpdateCheckService.available.value = UpdateInfo(
                        currentVersion: AppConstants.appVersion,
                        latestVersion: '${AppConstants.appVersion} (Test)',
                        releasePageUrl:
                            'https://github.com/chuk-development/Besser-Bahn/releases',
                      ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Privacy tagline
          Center(
            child: Text(
              'Die Bahn-App die nicht schnüffelt.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Picker for the transfer profile. A sheet rather than a dropdown: each
  /// option needs its one-line "why", or the labels alone ("Normal" vs "Mehr
  /// Zeit") don't say what actually changes.
  void _pickTransferProfile(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                'Umsteigeprofil',
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                'Wie schnell du umsteigst. Beeinflusst, ab wann die App einen '
                'Anschluss als knapp warnt — die Fahrplanzeiten selbst ändert '
                'es nicht. Bleibt auf dem Gerät.',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            // The group value and the handler live on the RadioGroup ancestor
            // since Flutter 3.32; the tiles only carry their own value.
            RadioGroup<TransferProfile>(
              groupValue: settings.transferProfile,
              onChanged: (v) {
                if (v != null) {
                  ref.read(settingsProvider.notifier).setTransferProfile(v);
                }
                Navigator.pop(ctx);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final p in TransferProfile.values)
                    RadioListTile<TransferProfile>(
                      value: p,
                      title: Text('${p.emoji}  ${p.label}'),
                      subtitle: Text(p.hint),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// What the offline travel packages (#29) cost in storage, and the way out.
///
/// Packages are deleted per trip from the Reisen list, but a package outlives
/// nothing else that shows it — a trip can be swiped away, the app reinstalled,
/// a download half-finished. Without one place that names the total and can
/// clear it, "downloaded a few trips" quietly becomes tens of megabytes nobody
/// can find.
class _OfflineStorageCard extends ConsumerWidget {
  const _OfflineStorageCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final packages = ref.watch(offlinePackagesProvider);
    final bytes = ref.watch(offlinePackagesSizeProvider);
    final count = packages.length;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.offline_pin_outlined),
            title: const Text('Offline-Reisepakete'),
            subtitle: Text(
              count == 0
                  ? 'Nichts gespeichert. In „Reisen" pro Reise speichern.'
                  : '$count ${count == 1 ? 'Reise' : 'Reisen'} · '
                        '${offlineSizeLabel(bytes)}',
            ),
            trailing: count == 0
                ? null
                : TextButton(
                    onPressed: () => _confirmClear(context, ref, count),
                    child: const Text('Löschen'),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClear(
    BuildContext context,
    WidgetRef ref,
    int count,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Alle Offline-Pakete löschen?'),
        content: Text(
          '$count gespeicherte ${count == 1 ? 'Reise' : 'Reisen'} '
          'werden entfernt. Die Reisen selbst bleiben — nur die offline '
          'verfügbaren Daten sind dann weg.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(offlinePackagesProvider.notifier).deleteAll();
  }
}

/// Opens [url] externally; on failure shows a SnackBar rather than dead-tapping
/// (a link with an "open" glyph that does nothing reads as broken — #48).
/// Ask for a password (twice when creating one), or null on cancel.
///
/// Typed twice on purpose for a *new* backup: the file is unreadable without
/// it, and there is nobody to reset it — a typo here is the whole backup gone.
Future<String?> _askPassword(BuildContext context, {required bool confirm}) {
  final first = TextEditingController();
  final second = TextEditingController();
  String? error;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(confirm ? 'Passwort festlegen' : 'Passwort der Sicherung'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: first,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Passwort'),
            ),
            if (confirm)
              TextField(
                controller: second,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Wiederholen'),
              ),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(
                error!,
                style: TextStyle(color: Theme.of(ctx).colorScheme.error),
              ),
            ],
            if (confirm) ...[
              const SizedBox(height: 12),
              const Text(
                'Ohne dieses Passwort lässt sich die Datei nicht mehr öffnen. '
                'Es gibt keinen Weg zurück.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () {
              if (first.text.isEmpty) {
                setState(() => error = 'Bitte ein Passwort eingeben.');
                return;
              }
              if (confirm && first.text != second.text) {
                setState(() => error = 'Die beiden stimmen nicht überein.');
                return;
              }
              Navigator.pop(ctx, first.text);
            },
            child: const Text('Weiter'),
          ),
        ],
      ),
    ),
  );
}

/// Build the encrypted file and hand it to the system share sheet (#72).
Future<void> _createBackup(BuildContext context) async {
  final password = await _askPassword(context, confirm: true);
  if (password == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final file = await BackupService().writeBackup(password);
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], subject: 'Besser-Bahn Sicherung'),
    );
  } on BackupError catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Sicherung fehlgeschlagen: $e')),
    );
  }
}

/// Pick a `.bbbk` file and write it back into the local stores (#72).
///
/// Restarting afterwards is not cosmetic: every provider read its state on
/// launch, so the running app still holds the old data until it does that
/// again.
Future<void> _restoreBackup(BuildContext context) async {
  final file = await FilePicker.pickFile();
  if (file == null || !context.mounted) return;
  final bytes = await file.readAsBytes();
  if (!context.mounted) return;

  final password = await _askPassword(context, confirm: false);
  if (password == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final n = await BackupService().restore(bytes, password);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '$n Einträge wiederhergestellt — bitte die App neu '
          'starten, damit alles geladen wird.',
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  } on BackupError catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Wiederherstellen fehlgeschlagen: $e')),
    );
  }
}

Future<void> _openUrl(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.of(context);
  var ok = false;
  try {
    ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    ok = false;
  }
  if (!ok) {
    messenger.showSnackBar(
      const SnackBar(content: Text("Konnte den Link nicht öffnen.")),
    );
  }
}
