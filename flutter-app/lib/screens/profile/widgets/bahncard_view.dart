import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../models/db_account.dart';
import '../../../providers/account_provider.dart';

/// Renders a single BahnCard. Prefers DB's own card artwork (`bildSicht`,
/// the exact image the DB Navigator app shows); falls back to a styled card
/// built from the card's fields when no artwork is available.
class BahnCardView extends StatelessWidget {
  final DbBahnCard card;
  const BahnCardView({super.key, required this.card});

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(16);
    final hasControl = card.kontrollSicht != null;
    final child = card.bildSicht != null
        ? ClipRRect(
            borderRadius: radius,
            child: AspectRatio(
              aspectRatio: 1.586, // ID-1 / credit-card ratio
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(
                    card.bildSicht!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => _fallback(context),
                  ),
                  if (hasControl)
                    Positioned(
                      right: 10,
                      bottom: 10,
                      child: _ControlChip(),
                    ),
                ],
              ),
            ),
          )
        : _fallback(context);
    return InkWell(
      borderRadius: radius,
      onTap: hasControl ? () => _openControlView(context) : null,
      child: child,
    );
  }

  void _openControlView(BuildContext context) =>
      openBahnCardControl(context, card);

  Widget _fallback(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.586,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFEC0016), Color(0xFF9B0010)],
          ),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              card.produktBezeichnung.isNotEmpty
                  ? card.produktBezeichnung
                  : card.typ,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            if (card.karteninhaber != null)
              Text(
                card.karteninhaber!,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  card.firstClass ? '1. Klasse' : '2. Klasse',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85), fontSize: 13),
                ),
                if (card.gueltigBis != null)
                  Text(
                    'gültig bis ${_d(card.gueltigBis!)}',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 13),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _d(String iso) {
    final dt = DateTime.tryParse(iso);
    return dt != null ? DateFormat('dd.MM.yyyy').format(dt) : iso;
  }
}

class _ControlChip extends StatelessWidget {
  const _ControlChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.verified_user, color: Colors.white, size: 14),
          SizedBox(width: 4),
          Text('Kontrolle',
              style: TextStyle(color: Colors.white, fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Open DB's BahnCard Kontrollansicht for [card] — same screen as tapping the
/// card in Profil, exposed so the Ticket view can jump to it (a conductor
/// usually checks both, so the user needs a fast switch).
void openBahnCardControl(BuildContext context, DbBahnCard card) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _BahnCardControlScreen(card: card),
    ),
  );
}

/// Open the first BahnCard's Kontrollansicht, or show a snackbar explaining
/// why nothing happened (still loading / endpoint failed / no BahnCard in the
/// account). Always-visible Ticket-AppBar action — never a silent no-op.
Future<void> openFirstBahnCardControl(
    BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  final async = ref.read(bahncardsProvider);
  final cards = async.asData?.value;
  if (cards != null && cards.isNotEmpty) {
    openBahnCardControl(context, cards.first);
    return;
  }
  if (cards != null && cards.isEmpty) {
    messenger.showSnackBar(
        const SnackBar(content: Text('Keine BahnCard im Konto.')));
    return;
  }
  // Loading or error — kick a fresh fetch and report.
  messenger.showSnackBar(
      const SnackBar(content: Text('BahnCard wird geladen …')));
  ref.invalidate(bahncardsProvider);
  try {
    final fresh = await ref.read(bahncardsProvider.future);
    if (!context.mounted) return;
    if (fresh.isEmpty) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Keine BahnCard im Konto.')));
      return;
    }
    openBahnCardControl(context, fresh.first);
  } catch (e) {
    if (!context.mounted) return;
    messenger.showSnackBar(SnackBar(content: Text('BahnCard nicht ladbar: $e')));
  }
}

/// Fullscreen Kontrollansicht — the control-view image DB shows for ticket
/// inspection, the same `kontrollSicht` PNG the DB Navigator app renders.
class _BahnCardControlScreen extends StatelessWidget {
  final DbBahnCard card;
  const _BahnCardControlScreen({required this.card});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('BahnCard · Kontrolle'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (card.karteninhaber != null) ...[
                Text(card.karteninhaber!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
              ],
              Text(card.produktBezeichnung,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 14)),
              const SizedBox(height: 12),
              Expanded(
                child: InteractiveViewer(
                  maxScale: 4,
                  child: Center(
                    child: card.kontrollSicht != null
                        ? Image.memory(card.kontrollSicht!,
                            fit: BoxFit.contain, gaplessPlayback: true)
                        : const Text('Keine Kontrollansicht verfügbar.',
                            style: TextStyle(color: Colors.white70)),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text('BahnCard-Nr ${card.nummer}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
              if (card.gueltigBis != null)
                Text(
                  'BahnCard gültig bis ${_fmt(card.gueltigBis!)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              if (card.kontrollSichtGueltigBis != null)
                Text(
                  'Kontrollansicht gültig bis '
                  '${_fmt(card.kontrollSichtGueltigBis!)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmt(String iso) {
    final dt = DateTime.tryParse(iso);
    return dt != null ? DateFormat('dd.MM.yyyy').format(dt) : iso;
  }
}
