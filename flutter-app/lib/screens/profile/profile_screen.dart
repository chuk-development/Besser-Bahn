import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../models/db_account.dart';
import '../../models/db_ticket.dart';
import '../../providers/account_provider.dart';
import 'widgets/bahncard_view.dart';

/// "Profil" tab — the signed-in DB account: identity, BahnBonus, BahnCards and
/// booked tickets. Logged out, it shows a single DB-login call to action.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the app — e.g. after completing a purchase or correcting
    // the address on bahn.de — re-pull the account so the change is there
    // without a manual refresh.
    //
    // The same one-call refresh the pull uses, including the profile itself:
    // this handler used to refresh BahnBonus, BahnCards and the trip overview
    // but never the profile, so an address edited outside the app stayed on the
    // old value until a re-login (#31). `auto` throttles it — resume fires far
    // more often than the account changes.
    if (state == AppLifecycleState.resumed) {
      ref.read(accountRefreshProvider).refresh(auto: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(dbAuthProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profil'),
        actions: [
          if (auth.isLoggedIn)
            IconButton(
              tooltip: 'Abmelden',
              icon: const Icon(Icons.logout),
              onPressed: () => _confirmLogout(context),
            ),
        ],
      ),
      body: !auth.initialized
          ? const Center(child: CircularProgressIndicator())
          : auth.isLoggedIn
              ? _LoggedIn(auth: auth)
              : _LoggedOut(auth: auth),
    );
  }

  void _confirmLogout(BuildContext context) async {
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

class _LoggedOut extends ConsumerStatefulWidget {
  final DbAuthState auth;
  const _LoggedOut({required this.auth});

  @override
  ConsumerState<_LoggedOut> createState() => _LoggedOutState();
}

class _LoggedOutState extends ConsumerState<_LoggedOut> {
  // The user must explicitly acknowledge the ban risk before login is enabled.
  bool _accepted = false;

  @override
  Widget build(BuildContext context) {
    final auth = widget.auth;
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
            const SizedBox(height: 20),
            // Ban-risk disclaimer: this app is unofficial and the login goes
            // through an unofficial interface, which the DB could in theory
            // penalise. Make the risk explicit and require acknowledgement.
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer.withAlpha(90),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 20, color: theme.colorScheme.error),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Diese App ist inoffiziell und nicht mit der Deutschen '
                      'Bahn verbunden. Die Anmeldung nutzt eine inoffizielle '
                      'Schnittstelle — theoretisch kann die Bahn dein Konto '
                      'dafür einschränken oder sperren. Die Nutzung erfolgt auf '
                      'eigenes Risiko; für Kontosperren oder daraus entstehende '
                      'Schäden übernehmen wir keine Haftung.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            CheckboxListTile(
              value: _accepted,
              onChanged: (v) => setState(() => _accepted = v ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(
                'Ich habe das Risiko verstanden und melde mich auf eigene '
                'Verantwortung an.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 12),
            if (auth.error != null) ...[
              Text(auth.error!,
                  style: TextStyle(color: theme.colorScheme.error),
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
            ],
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: (auth.isLoading || !_accepted)
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
  final DbAuthState auth;
  const _LoggedIn({required this.auth});

  DbProfile get profile => auth.profile!;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bahnbonus = ref.watch(bahnbonusProvider);
    final cards = ref.watch(bahncardsProvider);
    final tickets = ref.watch(ticketIndicesProvider);

    return RefreshIndicator(
      // One pull = one coordinated set of requests for every source on this
      // screen: profile/address, BahnBonus, BahnCards, tickets. The screen used
      // to refresh each of them by hand while also invalidating them, which
      // fired every request twice and rate-limited the refresh into serving the
      // stale cache it was meant to replace (#31).
      onRefresh: () => ref.read(accountRefreshProvider).refresh(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _header(context),
          _refreshStatus(context),
          const SizedBox(height: 16),
          // BahnBonus — same rule as BahnCard below: never blank the card just
          // because a refresh is in flight or failed. `.value` (unlike
          // `asData`, which nulls out on loading/error) retains the last good
          // value across a refresh, so the card stays put (#12). Only a
          // genuinely BahnBonus-less account renders nothing.
          if (bahnbonus.value case final bb?) _BahnBonusCard(bonus: bb),
          _detailsCard(context),
          const SizedBox(height: 20),
          // BahnCards — section always renders so the user can see *why*
          // there's nothing here when the endpoint failed (silent SizedBox.
          // shrink was hiding the bug; now error/empty surface explicitly).
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitle(context, 'BahnCard'),
              cards.when(
                data: (list) => list.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'Keine BahnCard in deinem Konto.',
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.outline),
                        ),
                      )
                    : Column(
                        children: [
                          for (final c in list)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: _BahnCardTile(card: c),
                            ),
                        ],
                      ),
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline,
                          size: 18,
                          color: Theme.of(context).colorScheme.error),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text('BahnCard nicht ladbar: $e',
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      ),
                      TextButton(
                        onPressed: () => ref
                            .read(bahncardsProvider.notifier)
                            .refresh(),
                        child: const Text('Erneut'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
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

  /// "Zuletzt aktualisiert …" — so a pull that found nothing new is visibly
  /// different from a pull that failed. A failed refresh used to be invisible
  /// here: the error landed in the state, and only the logged-out view ever
  /// rendered it, so a rate-limited refresh looked like "nothing changed" (#31).
  Widget _refreshStatus(BuildContext context) {
    final theme = Theme.of(context);
    final failed = auth.error != null;
    final at = auth.lastRefreshedAt;
    if (!failed && at == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Icon(
            failed ? Icons.sync_problem : Icons.sync,
            size: 14,
            color: failed ? theme.colorScheme.error : theme.colorScheme.outline,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              failed
                  ? auth.error!
                  : 'Zuletzt aktualisiert: '
                      '${DateFormat('dd.MM.yyyy, HH:mm').format(at!)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color:
                    failed ? theme.colorScheme.error : theme.colorScheme.outline,
              ),
            ),
          ),
        ],
      ),
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
      // Long-press → copy. Mirrors what users expect from a contact-detail row:
      // grab the Kundennummer / E-Mail / address with one gesture, paste it
      // into a form. Snackbar confirms which field landed in the clipboard.
      onLongPress: () async {
        await Clipboard.setData(ClipboardData(text: value));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 2),
            content: Text('$label kopiert'),
          ),
        );
      },
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

/// One BahnCard tile in the Profil list: the official card art on top, with
/// BC-Nr and "Gültig bis" rendered as muted text directly underneath. The
/// metadata used to live inside the fullscreen Kontrollansicht; the user
/// preferred it here so the card stays clean and the basic data is glanceable
/// without opening anything.
class _BahnCardTile extends StatelessWidget {
  final DbBahnCard card;
  const _BahnCardTile({required this.card});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.outline;
    final parts = <String>[
      'Nr. ${_formatBcNumber(card.nummer)}',
      if (card.gueltigBis != null) 'gültig bis ${_d(card.gueltigBis!)}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        BahnCardView(card: card),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
          child: Text(parts.join(' · '),
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: muted)),
        ),
      ],
    );
  }

  /// "7081411251741233" → "7081 4112 5174 1233" so the long number breaks
  /// visually like a credit card. No-op if already spaced.
  static String _formatBcNumber(String raw) {
    if (raw.contains(' ')) return raw;
    final buf = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      if (i > 0 && i % 4 == 0) buf.write(' ');
      buf.write(raw[i]);
    }
    return buf.toString();
  }

  static String _d(String iso) {
    final dt = DateTime.tryParse(iso);
    return dt != null ? DateFormat('dd.MM.yyyy').format(dt) : iso;
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
