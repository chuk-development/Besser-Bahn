import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/offline_package.dart';
import '../models/journey.dart';
import '../providers/connectivity_provider.dart';
import '../providers/offline_package_provider.dart';

/// The per-journey offline row in the Reisen list (#29).
///
/// The whole point of the feature: without a visible, honest state nobody trusts
/// an offline package enough to rely on it. So this always says three things —
/// what we have, how old it is, and how big it is — and never rounds any of them
/// up. Tapping opens the per-part breakdown.
class OfflinePackageBar extends ConsumerWidget {
  const OfflinePackageBar({
    super.key,
    required this.journey,
    required this.journeyKey,
  });

  final Journey journey;
  final String journeyKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(offlinePackageProvider(journeyKey));

    // Top up a package the user already asked for, if departure is near and
    // there's network. Deferred to a microtask inside, so this is safe here.
    maybeAutoRefreshPackage(ref, journeyKey, journey);

    final theme = Theme.of(context);
    final state = status.state;
    final color = _color(theme, state);

    return InkWell(
      onTap: () => _openDetails(context, ref),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
        child: Row(
          children: [
            Icon(_icon(state), size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(child: _summary(context, status, color)),
            _action(context, ref, status),
          ],
        ),
      ),
    );
  }

  Widget _summary(
      BuildContext context, OfflinePackageStatus status, Color color) {
    final theme = Theme.of(context);
    final state = status.state;

    if (state == OfflinePackageState.downloading) {
      final p = status.progress;
      final label = p == null
          ? 'Lädt…'
          : 'Lädt ${p.kind.label}… ${p.done}/${p.total}';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: theme.textTheme.bodySmall?.copyWith(color: color)),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              minHeight: 3,
              // Indeterminate until a part reports a total — a fake precise bar
              // is worse than an honest spinner.
              value: (p == null || p.total == 0) ? null : p.done / p.total,
            ),
          ),
        ],
      );
    }

    // Every non-trivial state carries its age; an offline package without a
    // "Stand" is exactly the thing nobody can act on.
    final bits = <String>[state.label];
    final age = status.ageLabel;
    if (age != null && state != OfflinePackageState.missing) {
      bits.add('Stand $age');
    }
    if (status.bytes > 0) bits.add(status.sizeLabel);

    return Text(
      bits.join(' · '),
      style: theme.textTheme.bodySmall?.copyWith(color: color),
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _action(
      BuildContext context, WidgetRef ref, OfflinePackageStatus status) {
    final state = status.state;
    if (state == OfflinePackageState.downloading) {
      return const SizedBox(width: 40);
    }
    if (state == OfflinePackageState.missing) {
      return TextButton(
        onPressed: () => _download(context, ref),
        child: const Text('Speichern'),
      );
    }
    return IconButton(
      icon: const Icon(Icons.more_horiz, size: 20),
      tooltip: 'Offline-Paket',
      onPressed: () => _openDetails(context, ref),
    );
  }

  Future<void> _download(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(offlinePackagesProvider.notifier)
          .download(journeyKey, journey);
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Offline-Paket konnte nicht geladen werden.'),
      ));
    }
  }

  void _openDetails(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _OfflinePackageSheet(
        journey: journey,
        journeyKey: journeyKey,
      ),
    );
  }

  static IconData _icon(OfflinePackageState state) => switch (state) {
        OfflinePackageState.missing => Icons.cloud_download_outlined,
        OfflinePackageState.downloading => Icons.downloading,
        OfflinePackageState.failed => Icons.error_outline,
        OfflinePackageState.partial => Icons.cloud_queue,
        OfflinePackageState.stale => Icons.schedule,
        OfflinePackageState.ready => Icons.offline_pin,
      };

  static Color _color(ThemeData theme, OfflinePackageState state) =>
      switch (state) {
        OfflinePackageState.missing => theme.colorScheme.onSurfaceVariant,
        OfflinePackageState.downloading => theme.colorScheme.primary,
        OfflinePackageState.failed => theme.colorScheme.error,
        // Both "usable but qualified" states share the warning colour: the
        // rider's takeaway is identical — you can use this, but check it.
        OfflinePackageState.partial => theme.colorScheme.tertiary,
        OfflinePackageState.stale => theme.colorScheme.tertiary,
        OfflinePackageState.ready => theme.colorScheme.primary,
      };
}

/// "Offline — Daten vom …" strip for a screen that is currently serving a
/// package's cached data (#29).
///
/// The app-wide [OfflineBanner] says the device has no network; this says how
/// old the data in front of you actually is. That's the part a rider can act on:
/// a plan from 20 minutes ago is worth trusting, one from yesterday evening is
/// not. Hides itself when online, or when there's no package to have served.
class OfflineDataNotice extends ConsumerWidget {
  const OfflineDataNotice({super.key, required this.journeyKey});

  final String journeyKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(isOfflineProvider)) return const SizedBox.shrink();
    final status = ref.watch(offlinePackageProvider(journeyKey));
    if (!status.state.hasUsableData) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final age = status.ageLabel;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.offline_pin,
              size: 18, color: theme.colorScheme.onSecondaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              status.state == OfflinePackageState.partial
                  ? 'Offline — gespeicherte Daten von $age, unvollständig. '
                      'Keine Echtzeit.'
                  : 'Offline — gespeicherte Daten von $age. Keine Echtzeit.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Per-part breakdown: what a package actually holds, and why it's short.
class _OfflinePackageSheet extends ConsumerWidget {
  const _OfflinePackageSheet({required this.journey, required this.journeyKey});

  final Journey journey;
  final String journeyKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(offlinePackageProvider(journeyKey));
    final theme = Theme.of(context);
    final manifest = status.manifest;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Offline-Reisepaket', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              status.state == OfflinePackageState.missing
                  ? 'Noch nichts gespeichert. Im Zug ist genau dann kein Netz, '
                      'wenn du die Daten brauchst.'
                  : '${status.state.label} · Stand ${status.ageLabel} · '
                      '${status.sizeLabel}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            if (manifest != null) ...[
              for (final part in manifest.parts) _partRow(context, part),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                if (manifest != null)
                  TextButton.icon(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Löschen'),
                    onPressed: () async {
                      final nav = Navigator.of(context);
                      await ref
                          .read(offlinePackagesProvider.notifier)
                          .delete(journeyKey);
                      nav.pop();
                    },
                  ),
                const Spacer(),
                FilledButton.icon(
                  icon: Icon(
                    manifest == null ? Icons.download : Icons.refresh,
                    size: 18,
                  ),
                  label: Text(manifest == null ? 'Speichern' : 'Aktualisieren'),
                  onPressed: status.state == OfflinePackageState.downloading
                      ? null
                      : () {
                          Navigator.of(context).pop();
                          ref
                              .read(offlinePackagesProvider.notifier)
                              .download(journeyKey, journey)
                              .catchError((_) {});
                        },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _partRow(BuildContext context, OfflinePart part) {
    final theme = Theme.of(context);
    // An empty source is "nothing to carry", not a gap — say so plainly rather
    // than showing a scary 0/0.
    final (IconData icon, Color color, String trailing) = part.isEmptySource
        ? (Icons.remove, theme.colorScheme.onSurfaceVariant, '—')
        : part.isComplete
            ? (
                Icons.check_circle,
                theme.colorScheme.primary,
                offlineSizeLabel(part.bytes)
              )
            : (
                Icons.error_outline,
                theme.colorScheme.tertiary,
                '${part.stored}/${part.expected}'
              );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(part.kind.label, style: theme.textTheme.bodyMedium),
                if (part.note != null)
                  Text(
                    part.note!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            trailing,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
