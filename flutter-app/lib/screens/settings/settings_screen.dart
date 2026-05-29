import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
import '../../models/split_ticket.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/traewelling_avatar_button.dart';

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
        actions: const [TraewellingAvatarButton()],
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
