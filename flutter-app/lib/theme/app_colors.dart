import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // Deutsche Bahn Brand Colors
  static const dbRed = Color(0xFFEC0016);
  static const dbRedDark = Color(0xFFC50014);

  /// DB "Verkehrsblau" — the blue used for station-map POI markers on
  /// bahnhof.de (lifts, stairs, exits, bus …).
  static const dbBlue = Color(0xFF1455C0);

  // Functional colors
  static const delay = Color(0xFFE74C3C);
  static const onTime = Color(0xFF27AE60);
  static const cancelled = Color(0xFF95A5A6);
  static const warning = Color(0xFFF39C12);

  // Coach sequence — saturated enough to fill a whole car body and still read.
  static const firstClass = Color(0xFFE3B23C); // warm gold (1. Klasse)
  static const secondClass = Color(0xFF2F6CC0); // clean DB blue (2. Klasse)

  /// The rider's own reserved seat in a seat plan — violet, so it stands out
  /// from free (green), taken (grey) and both class colours.
  static const mySeat = Color(0xFF7B3FE4);
  static const restaurant = Color(0xFFC85C2E); // warm terracotta (Bordbistro)
  static const locomotive = Color(0xFF5B6770); // graphite Triebkopf
  static const closedCoach = Color(0xFFB0B8BE);

  /// Readable text/icon colour on top of a filled class colour.
  static Color onClass(Color c) =>
      c.computeLuminance() > 0.5 ? const Color(0xDD000000) : Colors.white;
}
