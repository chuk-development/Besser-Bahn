import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../models/db_account.dart';

/// Renders a single BahnCard. Prefers DB's own card artwork (`bildSicht`,
/// the exact image the DB Navigator app shows); falls back to a styled card
/// built from the card's fields when no artwork is available.
class BahnCardView extends StatelessWidget {
  final DbBahnCard card;
  const BahnCardView({super.key, required this.card});

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(16);
    if (card.bildSicht != null) {
      return ClipRRect(
        borderRadius: radius,
        child: AspectRatio(
          aspectRatio: 1.586, // ID-1 / credit-card ratio
          child: Image.memory(
            card.bildSicht!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _fallback(context),
          ),
        ),
      );
    }
    return _fallback(context);
  }

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
