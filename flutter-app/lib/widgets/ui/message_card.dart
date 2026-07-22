import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// What a message on a screen actually is. Drives how loud it may be (#38).
enum MessageTone {
  /// Neutral context — a note, a disclaimer, a "how this works". Quiet.
  info,

  /// Something the rider should act on, but nothing is broken yet: a tight
  /// transfer, a fare that binds to one train.
  caution,

  /// Broken: a cancelled train, a failed load, a missed connection.
  alert,

  /// The app suggesting something good — a cheaper split, a better departure.
  recommendation,
}

/// One card for every "the app is telling you something" block.
///
/// The app grew a dozen of these, each inventing its own look: whole cards
/// filled with `errorContainer`, `secondaryContainer`, tinted alpha washes.
/// Everything ended up shouting equally loudly, so nothing read as important
/// (#38). This is the shared shape — a tinted surface with a coloured accent
/// rail and a small icon, colour reserved for the accent and the title, never
/// for a whole panel.
///
/// Layout: accent rail · icon · (title, body) · optional [trailing].
class MessageCard extends StatelessWidget {
  final MessageTone tone;

  /// Short and concrete. Optional: a one-line note needs only [body].
  final String? title;
  final String body;

  /// Overrides the tone's default icon.
  final IconData? icon;

  /// A single action — a text button, not a filled one: this is never the
  /// primary action of a screen.
  final Widget? trailing;

  /// Whole-card tap, e.g. to open the thing being talked about.
  final VoidCallback? onTap;

  final EdgeInsets margin;

  const MessageCard({
    super.key,
    required this.body,
    this.tone = MessageTone.info,
    this.title,
    this.icon,
    this.trailing,
    this.onTap,
    this.margin = const EdgeInsets.fromLTRB(16, 8, 16, 0),
  });

  /// The one colour this card is allowed to use.
  Color accentOf(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return switch (tone) {
      MessageTone.info => scheme.outline,
      MessageTone.caution => AppColors.warning,
      MessageTone.alert => scheme.error,
      MessageTone.recommendation => AppColors.onTime,
    };
  }

  IconData get _icon =>
      icon ??
      switch (tone) {
        MessageTone.info => Icons.info_outline,
        MessageTone.caution => Icons.warning_amber_rounded,
        MessageTone.alert => Icons.error_outline,
        MessageTone.recommendation => Icons.lightbulb_outline,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = accentOf(context);
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_icon, size: 20, color: accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null) ...[
                  Text(
                    title!,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: tone == MessageTone.info
                          ? theme.colorScheme.onSurface
                          : accent,
                    ),
                  ),
                  const SizedBox(height: 2),
                ],
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );

    return Container(
      margin: margin,
      decoration: BoxDecoration(
        // A wash, not a fill: the surface stays a surface and the accent rail
        // carries the meaning.
        color: accent.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border(left: BorderSide(color: accent, width: 3)),
      ),
      clipBehavior: Clip.antiAlias,
      child: onTap == null
          ? content
          : InkWell(onTap: onTap, child: content),
    );
  }
}
