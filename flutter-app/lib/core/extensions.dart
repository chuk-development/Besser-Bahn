import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import 'berlin_time.dart';

extension DateTimeFormatting on DateTime {
  /// Wall-clock as DB prints it — Europe/Berlin, never the device's zone.
  /// A phone abroad showed every booked train an hour off (#106).
  tz.TZDateTime get berlin => toBerlin(this);

  // Formatted in German rail time (see [berlin]). DateFormat prints the raw
  // wall-clock fields, so a DateTime still flagged UTC (e.g. parsed from a
  // "…Z" timestamp) would print 2 h off — TZDateTime.from guards against
  // that and pins the zone.
  String get hhmm => DateFormat('HH:mm').format(berlin);

  String get dayMonthYear => DateFormat('dd.MM.yyyy').format(berlin);

  String get isoDate => DateFormat('yyyy-MM-dd').format(berlin);

  String get fullDateTime => DateFormat('dd.MM.yyyy HH:mm').format(berlin);
}

extension DelayFormatting on int {
  /// Format delay in seconds to human-readable string
  String get delayString {
    final minutes = this ~/ 60;
    if (minutes == 0) return '';
    return '+$minutes';
  }

  Color get delayColor {
    final minutes = this ~/ 60;
    if (minutes <= 0) return const Color(0xFF27AE60);
    if (minutes <= 5) return const Color(0xFFF39C12);
    return const Color(0xFFE74C3C);
  }
}

extension NullableDelayFormatting on int? {
  String get delayString => this?.delayString ?? '';
  Color get delayColor => this?.delayColor ?? const Color(0xFF27AE60);
}

extension StringCapitalize on String {
  String get capitalize =>
      isEmpty ? this : '${this[0].toUpperCase()}${substring(1)}';
}
