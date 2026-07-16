import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
import '../../core/offline_package.dart';
import '../../models/split_ticket.dart';
import '../../models/transfer_profile.dart';
import '../../models/traewelling_models.dart';
import '../../providers/offline_package_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/traewelling_provider.dart';
import '../../services/notification_service.dart';
import '../../widgets/traewelling_logo.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Einstellungen'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
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
                    child: Icon(Icons.train,
                        color: theme.colorScheme.onPrimaryContainer),
                  ),
                  const SizedBox(width: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(AppConstants.appName,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      Text('Version ${AppConstants.appVersion}',
                          style: theme.textTheme.bodySmall),
                    ],
                  ),
                ],
              ),
            ),
          ),

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
                      'für deine gespeicherten Reisen.'),
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
                          .map((m) => DropdownMenuItem(
                                value: m,
                                child: Text('$m Min'),
                              ))
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
                        'Kurz bevor dein Anschluss abfährt — mit Gleis & Übergang.'),
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
                      'damit du deinen Halt nicht verschläfst.'),
                  value: settings.arrivalAlertEnabled,
                  onChanged: (v) {
                    notifier.setArrivalAlertEnabled(v);
                    if (v) NotificationService.requestPermissions();
                  },
                ),
                if (settings.arrivalAlertEnabled) ...[
                  const Divider(height: 1),
                  SwitchListTile(
                    secondary: const Icon(Icons.alarm),
                    title: const Text('Klingeln statt nur vibrieren'),
                    subtitle: const Text(
                        '5 Min vorher laut klingeln, bis du es stoppst.'),
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
                      'Klingelt per Standort, sobald du am Ziel ankommst — '
                      'verspätungssicher (App muss offen sein).'),
                  value: settings.exitAlarmEnabled,
                  onChanged: (v) {
                    notifier.setExitAlarmEnabled(v);
                    if (v) NotificationService.requestPermissions();
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.directions_walk),
                  title: const Text('Umsteigeprofil'),
                  subtitle: Text(
                      '${settings.transferProfile.emoji} '
                      '${settings.transferProfile.label} — '
                      '${settings.transferProfile.hint}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _pickTransferProfile(context, ref, settings),
                ),
              ],
            ),
          ),

          _sectionHeader(context, 'Träwelling'),

          // Träwelling login/account — moved here from the tab AppBars so it
          // lives in one place: log in/out and reach the hub from Settings.
          Builder(builder: (context) {
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
                            backgroundImage: NetworkImage(user!.profilePicture!),
                          )
                        // Official Träwelling logo when not signed in.
                        : const TraewellingLogo(size: 32),
                    title: Text(loggedIn ? user.displayName : 'Träwelling'),
                    subtitle: Text(loggedIn
                        ? '@${user.username} · angemeldet'
                        : 'Nicht angemeldet · zum Einloggen tippen'),
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
                          'sofort ein – ohne Nachfrage.'),
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
                            .map((v) => DropdownMenuItem(
                                  value: v.value,
                                  child: Text(v.label,
                                      style: const TextStyle(fontSize: 14)),
                                ))
                            .toList(),
                      ),
                    ),
                  ],
                ],
              ),
            );
          }),

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
                        child: Text(bc.label, style: const TextStyle(fontSize: 14)),
                      );
                    }).toList(),
                  ),
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
                  onTap: () {
                    // TODO: Open privacy policy
                  },
                ),
              ],
            ),
          ),

          _sectionHeader(context, 'Über'),

          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.code),
                  title: Text('Open Source'),
                  subtitle: Text('Quellcode auf GitHub'),
                ),
                const Divider(height: 1),
                const ListTile(
                  leading: Icon(Icons.favorite_outline),
                  title: Text('Feedback'),
                  subtitle: Text('Bugs melden oder Features vorschlagen'),
                ),
              ],
            ),
          ),

          _sectionHeader(context, 'Entwickler'),

          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: ListTile(
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('Debug-Log'),
              subtitle: const Text('Live-API-Aufrufe (vendo / bahn.de)'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/debug-log'),
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
      BuildContext context, WidgetRef ref, AppSettings settings) {
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
              child: Text('Umsteigeprofil',
                  style: Theme.of(ctx).textTheme.titleLarge),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                'Wie schnell du umsteigst. Beeinflusst, ab wann die App einen '
                'Anschluss als knapp warnt — die Fahrplanzeiten selbst ändert '
                'es nicht. Bleibt auf dem Gerät.',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant),
              ),
            ),
            for (final p in TransferProfile.values)
              RadioListTile<TransferProfile>(
                value: p,
                groupValue: settings.transferProfile,
                title: Text('${p.emoji}  ${p.label}'),
                subtitle: Text(p.hint),
                onChanged: (v) {
                  if (v != null) {
                    ref.read(settingsProvider.notifier).setTransferProfile(v);
                  }
                  Navigator.pop(ctx);
                },
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
            subtitle: Text(count == 0
                ? 'Nichts gespeichert. In „Reisen" pro Reise speichern.'
                : '$count ${count == 1 ? 'Reise' : 'Reisen'} · '
                    '${offlineSizeLabel(bytes)}'),
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
      BuildContext context, WidgetRef ref, int count) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Alle Offline-Pakete löschen?'),
        content: Text('$count gespeicherte ${count == 1 ? 'Reise' : 'Reisen'} '
            'werden entfernt. Die Reisen selbst bleiben — nur die offline '
            'verfügbaren Daten sind dann weg.'),
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
