import 'package:flutter/material.dart';

/// The circled/boxed product label ("RE", "ICE", "RJX", "FLX", "BUS", …) shown
/// next to a train/line. Brand-ish colours per operator so EVERY product — DB,
/// ÖBB Railjet, Flixtrain/-bus, Nightjet — gets a recognisable filled badge,
/// not just RE/ICE. Pass [TransitLine.productBadge] as [label] (never empty).
class ProductBadge extends StatelessWidget {
  final String label;
  final double fontSize;
  const ProductBadge({super.key, required this.label, this.fontSize = 12});

  @override
  Widget build(BuildContext context) {
    final p = label.toUpperCase();
    final (Color bg, Color fg) = switch (p) {
      'ICE' => (Colors.white, Colors.red.shade700),
      'IC' || 'EC' || 'ECE' => (Colors.grey.shade200, Colors.grey.shade800),
      'RJ' || 'RJX' => (Colors.red.shade800, Colors.white), // ÖBB Railjet
      'NJ' || 'EN' => (Colors.indigo.shade900, Colors.white), // Nightjet/EN
      'FLX' || 'FLIXBUS' => (const Color(0xFF73D700), Colors.white), // Flix
      'TGV' => (Colors.indigo.shade700, Colors.white),
      'BUS' => (Colors.purple.shade400, Colors.white),
      // Official signage colours: green S-Bahn, blue U-Bahn, red tram.
      'S' || 'SBAHN' || 'S-BAHN' => (const Color(0xFF008D4F), Colors.white),
      'U' => (const Color(0xFF0065AE), Colors.white),
      'STR' || 'TRAM' => (const Color(0xFFD5001C), Colors.white),
      _ => (
        Theme.of(context).colorScheme.primaryContainer,
        Theme.of(context).colorScheme.onPrimaryContainer,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: fg.withAlpha(60)),
      ),
      child: Text(
        p,
        style: TextStyle(
          color: fg,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
