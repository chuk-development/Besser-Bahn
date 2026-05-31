import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../models/db_account.dart';
import '../../models/db_ticket.dart';
import '../../providers/account_provider.dart';
import 'widgets/bahncard_view.dart';

/// "Profil" tab — the signed-in DB account: identity, BahnBonus, BahnCards and
/// booked tickets. Logged out, it shows a single DB-login call to action.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(dbAuthProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profil'),
        actions: [
          if (auth.isLoggedIn)
            IconButton(
              tooltip: 'Abmelden',
              icon: const Icon(Icons.logout),
              onPressed: () => _confirmLogout(context, ref),
            ),
        ],
      ),
      body: !auth.initialized
          ? const Center(child: CircularProgressIndicator())
          : auth.isLoggedIn
              ? _LoggedIn(profile: auth.profile!)
              : _LoggedOut(auth: auth),
    );
  }

  void _confirmLogout(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Abmelden?'),
        content: const Text(
            'Dein DB-Konto wird aus der App entfernt. Profil, BahnCards und '
            'Tickets sind dann nicht mehr sichtbar.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Abmelden')),
        ],
      ),
    );
    if (ok == true) await ref.read(dbAuthProvider.notifier).logout();
  }
}

// --- Logged-out CTA ---------------------------------------------------------

class _LoggedOut extends ConsumerWidget {
  final DbAuthState auth;
  const _LoggedOut({required this.auth});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.account_circle_outlined,
                size: 96, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text('Mit DB-Konto anmelden',
                style: theme.textTheme.headlineSmall,
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Text(
              'Melde dich mit deinem Deutsche-Bahn-Konto an, um Profil, '
              'BahnBonus, deine BahnCard und gebuchte Tickets direkt hier zu '
              'sehen.',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Die Anmeldung läuft auf der Original-Seite der Bahn. Dein '
              'Passwort sieht diese App nie.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            if (auth.error != null) ...[
              Text(auth.error!,
                  style: TextStyle(color: theme.colorScheme.error),
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
            ],
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: auth.isLoading
                    ? null
                    : () => ref.read(dbAuthProvider.notifier).login(),
                icon: auth.isLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.login),
                label: Text(auth.isLoading ? 'Anmelden…' : 'Anmelden'),
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- Logged-in dashboard ----------------------------------------------------

class _LoggedIn extends ConsumerWidget {
  final DbProfile profile;
  const _LoggedIn({required this.profile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bahnbonus = ref.watch(bahnbonusProvider);
    final cards = ref.watch(bahncardsProvider);
    final tickets = ref.watch(ticketIndicesProvider);

    return RefreshIndicator(
      onRefresh: () async {
        await ref.read(dbAuthProvider.notifier).reload();
        ref.invalidate(bahnbonusProvider);
        ref.invalidate(bahncardsProvider);
        ref.invalidate(ticketIndicesProvider);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _header(context),
          const SizedBox(height: 16),
          bahnbonus.when(
            data: (bb) => bb == null
                ? const SizedBox.shrink()
                : _BahnBonusCard(bonus: bb),
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),
          _detailsCard(context),
          const SizedBox(height: 20),
          // BahnCards
          cards.when(
            data: (list) => list.isEmpty
                ? const SizedBox.shrink()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _sectionTitle(context, 'BahnCard'),
                      for (final c in list)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: BahnCardView(card: c),
                        ),
                      const SizedBox(height: 8),
                    ],
                  ),
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (_, _) => const SizedBox.shrink(),
          ),
          // Tickets
          _sectionTitle(context, 'Meine Tickets'),
          tickets.when(
            data: (list) => list.isEmpty
                ? _emptyTickets(context)
                : Column(
                    children: [
                      for (final t in list) _TicketTile(index: t),
                    ],
                  ),
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text('Tickets konnten nicht geladen werden.\n$e',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final initials = [
      if (profile.vorname.isNotEmpty) profile.vorname[0],
      if (profile.nachname.isNotEmpty) profile.nachname[0],
    ].join().toUpperCase();
    return Row(
      children: [
        CircleAvatar(
          radius: 32,
          backgroundColor: theme.colorScheme.primary,
          child: Text(
            initials.isEmpty ? '?' : initials,
            style: const TextStyle(
                color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                [profile.anredeText, profile.fullName]
                    .where((s) => s.isNotEmpty)
                    .join(' '),
                style: theme.textTheme.titleLarge,
              ),
              if (profile.email != null)
                Text(profile.email!,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.outline)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _detailsCard(BuildContext context) {
    final geb = profile.geburtsdatum;
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          _row(context, Icons.badge_outlined, 'Kundennummer',
              profile.kundennummer),
          if (profile.email != null)
            _row(context, Icons.email_outlined, 'E-Mail', profile.email!),
          if (geb != null)
            _row(context, Icons.cake_outlined, 'Geburtsdatum', _date(geb)),
          if (profile.adresse != null &&
              profile.adresse!.oneLine.isNotEmpty)
            _row(context, Icons.home_outlined, 'Adresse',
                profile.adresse!.oneLine),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, IconData icon, String label, String value) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(icon, color: theme.colorScheme.primary),
      title: Text(label, style: theme.textTheme.bodySmall),
      subtitle: Text(value, style: theme.textTheme.bodyLarge),
      dense: false,
    );
  }

  Widget _sectionTitle(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 10),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );

  Widget _emptyTickets(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text('Keine Tickets gefunden.',
              style: TextStyle(color: Theme.of(context).colorScheme.outline)),
        ),
      );

  static String _date(String iso) {
    final dt = DateTime.tryParse(iso);
    return dt != null ? DateFormat('dd.MM.yyyy').format(dt) : iso;
  }
}

class _BahnBonusCard extends StatelessWidget {
  final DbBahnBonus bonus;
  const _BahnBonusCard({required this.bonus});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.stars_rounded,
                color: theme.colorScheme.primary, size: 36),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('BahnBonus · ${bonus.levelName}',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    '${bonus.activeBonusPoints} Punkte · '
                    '${bonus.activeStatusPoints} Statuspunkte',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TicketTile extends StatelessWidget {
  final DbReiseIndex index;
  const _TicketTile({required this.index});

  @override
  Widget build(BuildContext context) {
    final kwId = index.kundenwunschIds.isNotEmpty
        ? index.kundenwunschIds.first
        : '';
    final date = index.aenderungsDatum;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.confirmation_number_outlined),
        title: Text('Auftrag ${index.auftragsnummer}'),
        subtitle: date != null
            ? Text(DateFormat('dd.MM.yyyy').format(date))
            : null,
        trailing: const Icon(Icons.chevron_right),
        onTap: kwId.isEmpty
            ? null
            : () => context.push('/ticket', extra: {
                  'auftragsnummer': index.auftragsnummer,
                  'kundenwunschId': kwId,
                }),
      ),
    );
  }
}
