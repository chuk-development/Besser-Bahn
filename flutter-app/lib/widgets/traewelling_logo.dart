import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The official Träwelling logo (their `images/icons/logo.svg`), bundled as an
/// asset. Use this instead of a generic Material icon wherever we represent the
/// Träwelling brand (settings tile, connect prompt, check-in buttons).
///
/// The asset is one white path, made for Träwelling's own red header. On our
/// light surfaces it was next to invisible (#109), so it is always tinted:
/// by default in the surrounding icon colour, like the icons next to it.
class TraewellingLogo extends StatelessWidget {
  final double size;

  /// Tint for the mark. Null = the ambient [IconTheme] colour.
  final Color? color;

  const TraewellingLogo({super.key, this.size = 32, this.color});

  @override
  Widget build(BuildContext context) {
    final tint =
        color ??
        IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurfaceVariant;
    return SvgPicture.asset(
      'assets/traewelling/traewelling_logo.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
      // The mark fails to a transparent box rather than throwing if the asset
      // is ever missing.
      placeholderBuilder: (_) => SizedBox(width: size, height: size),
    );
  }
}
