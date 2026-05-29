import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/traewelling_models.dart';
import '../../providers/traewelling_provider.dart';
import '../../theme/app_colors.dart';
import '../../widgets/trwl_status_card.dart';

/// The Träwelling hub: a connect prompt when logged out, or the user's own
/// profile + navigation to feed / check-in / friends when logged in.
class TraewellingHubScreen extends ConsumerWidget {
  const TraewellingHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(traewellingAuthProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Träwelling')),
      body: !auth.initialized
          ? const Center(child: CircularProgressIndicator())
          : auth.isLoggedIn
              ? _Profile(user: auth.user!)
              : _ConnectPrompt(auth: auth),
    );
  }
}

class _ConnectPrompt extends ConsumerWidget {
  final TraewellingAuthState auth;
  const _ConnectPrompt({required this.auth});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.share_location, size: 72, color: AppColors.dbRed),
            const SizedBox(height: 16),
            Text('Mit Träwelling verbinden',
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Text(
              'Checke in deine Züge ein, teile deine Fahrten mit Freund:innen '
              'und folge anderen. Träwelling ist ein kostenloser, '
              'gemeinnütziger Check-in-Dienst für den ÖPNV.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.outline),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            if (auth.error != null) ...[
              Text(auth.error!,
                  style: TextStyle(color: theme.colorScheme.error),
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
            ],
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.dbRed,
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              ),
              onPressed: auth.isLoading
                  ? null
                  : () => ref.read(traewellingAuthProvider.notifier).login(),
              icon: auth.isLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.login),
              label: Text(auth.isLoading ? 'Verbinde…' : 'Anmelden'),
            ),
            const SizedBox(height: 12),
            Text('Du wirst zu traewelling.de weitergeleitet.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ],
        ),
      ),
    );
  }
}

class _Profile extends ConsumerWidget {
  final TrwlUser user;
  const _Profile({required this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final statuses = ref.watch(trwlUserStatusesProvider(user.username));

    return RefreshIndicator(
      onRefresh: () async {
        await ref.read(traewellingAuthProvider.notifier).refreshUser();
        ref.invalidate(trwlUserStatusesProvider(user.username));
      },
      child: ListView(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 32,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  backgroundImage: (user.profilePicture?.isNotEmpty ?? false)
                      ? NetworkImage(user.profilePicture!)
                      : null,
                  child: (user.profilePicture?.isNotEmpty ?? false)
                      ? null
                      : Text(
                          user.displayName.isNotEmpty
                              ? user.displayName[0].toUpperCase()
                              : '?',
                          style: theme.textTheme.headlineSmall),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(user.displayName,
                          style: theme.textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      Text('@${user.username}',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: theme.colorScheme.outline)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Stats
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _stat(theme, user.distanceKm.toStringAsFixed(0), 'km'),
              _stat(theme, _hours(user.totalDuration), 'unterwegs'),
              _stat(theme, '${user.points}', 'Punkte'),
            ],
          ),
          const SizedBox(height: 8),
          // Actions
          _action(context, Icons.dynamic_feed, 'Feed',
              'Fahrten von Leuten, denen du folgst', () => context.push('/trawelling/feed')),
          _action(context, Icons.add_location_alt, 'Einchecken',
              'In einen Zug einchecken', () => context.push('/trawelling/checkin')),
          _action(context, Icons.people, 'Freunde',
              'Follower, Following & Anfragen', () => context.push('/trawelling/friends')),
          const Divider(height: 24),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Abmelden'),
            onTap: () => ref.read(traewellingAuthProvider.notifier).logout(),
          ),
          const Divider(height: 24),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Meine letzten Fahrten',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ),
          statuses.when(
            loading: () => const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator())),
            error: (e, _) => Padding(
                padding: const EdgeInsets.all(20),
                child: Text('Fahrten konnten nicht geladen werden.',
                    style: TextStyle(color: theme.colorScheme.error))),
            data: (list) => list.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text('Noch keine Fahrten.',
                        style: TextStyle(color: theme.colorScheme.outline)))
                : Column(
                    children: list
                        .map((s) => TrwlStatusCard(status: s))
                        .toList()),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _stat(ThemeData theme, String value, String label) => Column(
        children: [
          Text(value,
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          Text(label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
        ],
      );

  Widget _action(BuildContext context, IconData icon, String title,
          String subtitle, VoidCallback onTap) =>
      ListTile(
        leading: Icon(icon, color: AppColors.dbRed),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      );

  static String _hours(int minutes) {
    final h = minutes ~/ 60;
    return h > 0 ? '${h}h' : '${minutes}min';
  }
}
