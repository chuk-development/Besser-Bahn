import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants.dart';
import '../../models/bahnbonus.dart';
import '../../providers/account_provider.dart';
import '../../providers/bahnbonus_provider.dart';
import '../../providers/service_providers.dart';
import '../../services/db_account_service.dart';

/// BahnBonus inside Besser-Bahn (#112): digital card to collect points,
/// points and status, vouchers and status benefits, swapping points for
/// rewards, the points history and a signed-in jump to the Prämienwelt.
///
/// Uses the official BahnBonus app's backend with its `fe_bb_app` token.
/// That token needs a one-time link with the existing DB login (no second
/// password); CO₂ in the Reisestatistik shares it.
class BahnBonusScreen extends ConsumerWidget {
  const BahnBonusScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loggedIn = ref.watch(dbAuthProvider.select((s) => s.isLoggedIn));
    final overview = ref.watch(bahnbonusOverviewProvider);
    final ctrl = ref.read(bahnbonusOverviewProvider.notifier);

    Widget body;
    if (!loggedIn) {
      body = const _Message(
        icon: Icons.login_rounded,
        text:
            'Melde dich im Profil mit deinem DB-Konto an, um BahnBonus '
            'zu nutzen.',
      );
    } else if (overview.isLoading && !overview.hasValue) {
      body = const Center(child: CircularProgressIndicator());
    } else if (ctrl.needsAuthorization) {
      body = _ConnectPrompt(onConnect: ctrl.connect);
    } else if (overview.value case final o?) {
      body = RefreshIndicator(
        onRefresh: ctrl.refresh,
        child: _OverviewList(overview: o),
      );
    } else if (overview.hasError) {
      body = _Message(
        icon: Icons.cloud_off_rounded,
        text:
            'BahnBonus konnte nicht geladen werden.\n${_errorText(overview.error)}',
        action: FilledButton.tonal(
          onPressed: ctrl.refresh,
          child: const Text('Erneut versuchen'),
        ),
      );
    } else {
      body = _ConnectPrompt(onConnect: ctrl.connect);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('BahnBonus')),
      body: body,
    );
  }
}

String _errorText(Object? e) =>
    e is DbAccountException ? e.message : (e?.toString() ?? '');

final _date = DateFormat('dd.MM.yyyy');
final _num = NumberFormat.decimalPattern('de');

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;
  const _Message({required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

class _ConnectPrompt extends StatelessWidget {
  final Future<void> Function() onConnect;
  const _ConnectPrompt({required this.onConnect});

  @override
  Widget build(BuildContext context) => _Message(
    icon: Icons.link_rounded,
    text:
        'Für Punkte-Verlauf, Gutscheine, Prämien und die digitale '
        'BahnBonus-Karte muss Besser-Bahn einmal mit BahnBonus verknüpft '
        'werden. Das nutzt dein DB-Konto, ein zweites Passwort brauchst '
        'du nicht.',
    action: FilledButton.icon(
      onPressed: onConnect,
      icon: const Icon(Icons.link_rounded),
      label: const Text('Mit BahnBonus verknüpfen'),
    ),
  );
}

class _OverviewList extends ConsumerWidget {
  final BahnbonusOverview overview;
  const _OverviewList({required this.overview});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final o = overview;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        if (o.stale)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Offline: zuletzt gespeicherter Stand.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        _DigitalCard(loyalty: o.loyalty),
        const SizedBox(height: 12),
        _PointsCard(overview: o),
        if (o.vouchers.isNotEmpty) ...[
          const _SectionTitle('Gutscheine & Statusvorteile'),
          for (final v in o.vouchers) _VoucherTile(voucher: v),
        ],
        if (o.swapOffers.isNotEmpty) ...[
          const _SectionTitle('Prämien gegen Punkte'),
          for (final offer in o.swapOffers)
            _SwapOfferTile(offer: offer, available: o.loyalty.bonus.points),
        ],
        const _SectionTitle('Mehr'),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.history_rounded),
                title: const Text('Punkteverlauf'),
                subtitle: const Text('Gesammelte und eingelöste Punkte'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const BahnBonusHistoryScreen(),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.redeem_rounded),
                title: const Text('Prämienwelt'),
                subtitle: const Text('Alle Prämien, angemeldet im Browser'),
                trailing: const Icon(Icons.open_in_new_rounded),
                onTap: () => _openSignedIn(
                  context,
                  ref,
                  Uri.parse(DbAccountConstants.praemienweltUrl),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.local_shipping_outlined),
                title: const Text('Meine Prämienbestellungen'),
                trailing: const Icon(Icons.open_in_new_rounded),
                onTap: () => _openSignedIn(
                  context,
                  ref,
                  Uri.parse(DbAccountConstants.praemienweltOrdersUrl),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Future<void> _openSignedIn(
  BuildContext context,
  WidgetRef ref,
  Uri target,
) async {
  final messenger = ScaffoldMessenger.of(context);
  Uri uri = target;
  try {
    uri = await ref.read(dbAccountServiceProvider).bahnbonusSessionLink(target);
  } catch (_) {
    // Not linked or offline: open the page unsigned, DB asks for login.
  }
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Browser konnte nicht geöffnet werden')),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}

Color _levelColor(BbLevel level) => switch (level) {
  BbLevel.none => const Color(0xFF0C3992),
  BbLevel.silber => const Color(0xFF8A9199),
  BbLevel.gold => const Color(0xFFB8860B),
  BbLevel.platin => const Color(0xFF3C4048),
};

/// Grouped in fours, easier to read out or type.
String _grouped(String raw) {
  final s = raw.replaceAll(' ', '');
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && i % 4 == 0) buf.write(' ');
    buf.write(s[i]);
  }
  return buf.toString();
}

/// The digital BahnBonus card. Partners and DB travel centres scan the
/// Aztec code to credit points ("Scan & Collect" in the official app).
class _DigitalCard extends StatelessWidget {
  final BbLoyalty loyalty;
  const _DigitalCard({required this.loyalty});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _levelColor(loyalty.level);
    return Card(
      color: color,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showFullscreen(context),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              _AztecBox(data: loyalty.cardPayload, size: 104),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'BahnBonus ${loyalty.level.label}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _grouped(loyalty.accountNumber),
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: Colors.white,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Zum Punktesammeln an der Kasse vorzeigen. '
                      'Tippen zum Vergrößern.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white.withAlpha(210),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showFullscreen(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _AztecBox(data: loyalty.cardPayload, size: 240),
              const SizedBox(height: 16),
              SelectableText(
                _grouped(loyalty.accountNumber),
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 20,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: loyalty.accountNumber));
                  Navigator.of(ctx).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('BahnBonus-Nummer kopiert')),
                  );
                },
                icon: const Icon(Icons.copy_rounded),
                label: const Text('Nummer kopieren'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Aztec code on a white quiet zone, readable in dark mode too.
class _AztecBox extends StatelessWidget {
  final String data;
  final double size;
  const _AztecBox({required this.data, required this.size});

  @override
  Widget build(BuildContext context) => Container(
    color: Colors.white,
    padding: EdgeInsets.all(size * 0.06),
    child: BarcodeWidget(
      barcode: Barcode.aztec(),
      data: data,
      width: size,
      height: size,
      color: Colors.black,
      backgroundColor: Colors.white,
      drawText: false,
      errorBuilder: (_, _) => SizedBox(
        width: size,
        height: size,
        child: const Icon(Icons.error_outline, color: Colors.black),
      ),
    ),
  );
}

class _PointsCard extends StatelessWidget {
  final BahnbonusOverview overview;
  const _PointsCard({required this.overview});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = overview.loyalty;
    final next = overview.nextLevel;
    final border = next == null
        ? null
        : overview.levelBorders.firstWhere((b) => b.level == next.level);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: _Figure(value: l.bonus.points, label: 'Prämienpunkte'),
                ),
                Expanded(
                  child: _Figure(value: l.status.points, label: 'Statuspunkte'),
                ),
              ],
            ),
            if (l.bonus.expiringPoints > 0 && l.bonus.expirationDate != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  '${_num.format(l.bonus.expiringPoints)} Prämienpunkte '
                  'verfallen am ${_date.format(l.bonus.expirationDate!)}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            if (l.bonus.advisedPoints > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${_num.format(l.bonus.advisedPoints)} Punkte vorgemerkt',
                  style: muted,
                ),
              ),
            const Divider(height: 24),
            Text(
              'Status ${l.level.label}'
              '${l.status.expirationDate != null ? ' · gültig bis ${_date.format(l.status.expirationDate!)}' : ''}',
              style: theme.textTheme.titleSmall,
            ),
            if (next != null &&
                border != null &&
                border.requiredPoints > 0) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: (l.status.points / border.requiredPoints).clamp(0, 1),
                color: _levelColor(next.level),
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
              ),
              const SizedBox(height: 6),
              Text(
                next.missing == 0
                    ? 'Genug Statuspunkte für ${next.level.label}'
                    : 'Noch ${_num.format(next.missing)} Statuspunkte bis '
                          '${next.level.label}',
                style: muted,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  final int value;
  final String label;
  const _Figure({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _num.format(value),
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        Text(label, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

class _VoucherTile extends StatelessWidget {
  final BbDigitalVoucher voucher;
  const _VoucherTile({required this.voucher});

  @override
  Widget build(BuildContext context) {
    final open = voucher.openCount;
    final total = voucher.vouchers.length;
    return Card(
      child: ListTile(
        leading: Icon(
          voucher.statusBenefit
              ? Icons.workspace_premium_rounded
              : Icons.confirmation_number_outlined,
        ),
        title: Text(voucher.title),
        subtitle: Text(
          total == 0 ? (voucher.text ?? '') : '$open von $total verfügbar',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => _VoucherScreen(voucher: voucher),
          ),
        ),
      ),
    );
  }
}

class _VoucherScreen extends StatelessWidget {
  final BbDigitalVoucher voucher;
  const _VoucherScreen({required this.voucher});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Open codes first, used ones last.
    final codes = [...voucher.vouchers]
      ..sort((a, b) => (a.redeemed ? 1 : 0) - (b.redeemed ? 1 : 0));
    return Scaffold(
      appBar: AppBar(title: Text(voucher.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (voucher.text != null) ...[
            Text(voucher.text!, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 16),
          ],
          for (final v in codes) _VoucherCodeCard(voucher: v),
          for (final p in voucher.infoPages)
            Card(
              child: ExpansionTile(
                title: Text(p.title.isEmpty ? 'Info' : p.title),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [SelectableText(_plain(p.content))],
              ),
            ),
        ],
      ),
    );
  }
}

/// The info pages may carry simple HTML; show it as text.
String _plain(String s) => s
    .replaceAll(RegExp(r'<br\s*/?>|</p>|</li>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '• ')
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();

class _VoucherCodeCard extends StatelessWidget {
  final BbVoucher voucher;
  const _VoucherCodeCard({required this.voucher});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final until = voucher.activeUntil ?? voucher.expirationDate;
    return Opacity(
      opacity: voucher.redeemed ? 0.5 : 1,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                voucher.redeemed
                    ? 'Eingelöst'
                    : until != null
                    ? 'Gültig bis ${_date.format(until.toLocal())}'
                    : 'Verfügbar',
                style: theme.textTheme.titleSmall,
              ),
              for (final c in voucher.components) ...[
                const SizedBox(height: 12),
                _Component(component: c, redeemed: voucher.redeemed),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Component extends StatelessWidget {
  final BbVoucherComponent component;
  final bool redeemed;
  const _Component({required this.component, required this.redeemed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = component;
    if (c.aztec != null && !redeemed) {
      return Center(child: _AztecBox(data: c.aztec!, size: 200));
    }
    if (c.code != null) {
      return Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (c.codeLabel != null)
                  Text(c.codeLabel!, style: theme.textTheme.labelSmall),
                SelectableText(
                  c.code!,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Code kopieren',
            icon: const Icon(Icons.copy_rounded),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: c.code!));
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Code kopiert')));
            },
          ),
        ],
      );
    }
    if (c.actionUri != null) {
      final uri = Uri.tryParse(c.actionUri!);
      if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
        return OutlinedButton.icon(
          onPressed: () => launchUrl(uri, mode: LaunchMode.externalApplication),
          icon: const Icon(Icons.open_in_new_rounded),
          label: Text(c.actionTitle ?? 'Öffnen'),
        );
      }
    }
    if (c.bahncard100Title != null || c.bahncard100Text != null) {
      return Text(
        [c.bahncard100Title, c.bahncard100Text].whereType<String>().join('\n'),
      );
    }
    if (c.information != null) {
      return Text(_plain(c.information!), style: theme.textTheme.bodyMedium);
    }
    return const SizedBox.shrink();
  }
}

class _SwapOfferTile extends ConsumerStatefulWidget {
  final BbSwapOffer offer;
  final int available;
  const _SwapOfferTile({required this.offer, required this.available});

  @override
  ConsumerState<_SwapOfferTile> createState() => _SwapOfferTileState();
}

class _SwapOfferTileState extends ConsumerState<_SwapOfferTile> {
  bool _busy = false;

  Future<void> _redeem() async {
    final offer = widget.offer;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(offer.title),
        content: Text(
          'Für ${_num.format(offer.points)} Prämienpunkte einlösen? '
          'Die Punkte werden sofort abgebucht.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Einlösen'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(bahnbonusOverviewProvider.notifier).redeem(offer);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${offer.title} eingelöst. Den Gutschein findest du unter '
            '„Gutscheine“.',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_errorText(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final offer = widget.offer;
    final enough = widget.available >= offer.points;
    return Card(
      child: ListTile(
        leading: offer.imageUrl != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(
                  offer.imageUrl!,
                  width: 48,
                  height: 48,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const Icon(Icons.redeem_rounded),
                ),
              )
            : const Icon(Icons.redeem_rounded),
        title: Text(offer.title),
        subtitle: Text(
          [
            if (offer.subtitle != null) offer.subtitle!,
            '${_num.format(offer.points)} Punkte',
          ].join(' · '),
        ),
        trailing: _busy
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : FilledButton.tonal(
                onPressed: enough ? _redeem : null,
                child: const Text('Einlösen'),
              ),
      ),
    );
  }
}

/// Points history with a switch between Prämien- and Statuspunkte.
class BahnBonusHistoryScreen extends ConsumerStatefulWidget {
  const BahnBonusHistoryScreen({super.key});

  @override
  ConsumerState<BahnBonusHistoryScreen> createState() =>
      _BahnBonusHistoryScreenState();
}

class _BahnBonusHistoryScreenState
    extends ConsumerState<BahnBonusHistoryScreen> {
  BbPointsType _type = BbPointsType.bonus;

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(bahnbonusHistoryProvider(_type));
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Punkteverlauf')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SegmentedButton<BbPointsType>(
              segments: const [
                ButtonSegment(
                  value: BbPointsType.bonus,
                  label: Text('Prämienpunkte'),
                ),
                ButtonSegment(
                  value: BbPointsType.status,
                  label: Text('Statuspunkte'),
                ),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.first),
            ),
          ),
          Expanded(
            child: history.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => _Message(
                icon: Icons.cloud_off_rounded,
                text: 'Verlauf konnte nicht geladen werden.\n${_errorText(e)}',
                action: FilledButton.tonal(
                  onPressed: () =>
                      ref.invalidate(bahnbonusHistoryProvider(_type)),
                  child: const Text('Erneut versuchen'),
                ),
              ),
              data: (h) {
                if (h.items.isEmpty) {
                  return const _Message(
                    icon: Icons.history_rounded,
                    text: 'Noch keine Buchungen.',
                  );
                }
                return NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n.metrics.extentAfter < 400) {
                      ref
                          .read(bahnbonusHistoryProvider(_type).notifier)
                          .loadMore();
                    }
                    return false;
                  },
                  child: ListView.separated(
                    itemCount: h.items.length + (h.hasMore ? 1 : 0),
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      if (i >= h.items.length) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      final t = h.items[i];
                      final pts = _type == BbPointsType.bonus
                          ? t.bonusPoints
                          : t.statusPoints;
                      final sign = pts > 0 ? '+' : '';
                      return ListTile(
                        title: Text(t.title),
                        subtitle: Text(
                          [
                            if (t.date != null) _date.format(t.date!),
                            if (t.details != null) t.details!,
                            if (t.earmarked) 'vorgemerkt',
                          ].join(' · '),
                        ),
                        trailing: Text(
                          '$sign${_num.format(pts)}',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: pts < 0
                                ? theme.colorScheme.error
                                : pts > 0
                                ? Colors.green.shade700
                                : null,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
