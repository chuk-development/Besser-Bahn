import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/service_providers.dart';
import '../../providers/traewelling_provider.dart';
import '../../widgets/trwl_status_card.dart';

/// The dashboard feed — recent check-ins from people the user follows.
class TraewellingFeedScreen extends ConsumerWidget {
  const TraewellingFeedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(trwlDashboardProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Feed')),
      body: feed.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _error(context, ref, e),
        data: (statuses) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(trwlDashboardProvider),
          child: statuses.isEmpty
              ? ListView(
                  children: [
                    const SizedBox(height: 120),
                    Icon(Icons.inbox,
                        size: 56, color: theme.colorScheme.outline),
                    const SizedBox(height: 12),
                    Center(
                      child: Text('Noch nichts im Feed.\nFolge Leuten, '
                          'um ihre Fahrten zu sehen.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: theme.colorScheme.outline)),
                    ),
                  ],
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: statuses.length,
                  itemBuilder: (context, i) {
                    final s = statuses[i];
                    return TrwlStatusCard(
                      status: s,
                      onLike: s.isLikable
                          ? () => _toggleLike(ref, s.id, s.liked)
                          : null,
                    );
                  },
                ),
        ),
      ),
    );
  }

  Future<void> _toggleLike(WidgetRef ref, int statusId, bool liked) async {
    final service = ref.read(traewellingServiceProvider);
    try {
      if (liked) {
        await service.unlike(statusId);
      } else {
        await service.like(statusId);
      }
      ref.invalidate(trwlDashboardProvider);
    } catch (_) {/* ignore — UI refreshes on next pull */}
  }

  Widget _error(BuildContext context, WidgetRef ref, Object e) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 12),
              Text('Feed konnte nicht geladen werden.',
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => ref.invalidate(trwlDashboardProvider),
                child: const Text('Erneut versuchen'),
              ),
            ],
          ),
        ),
      );
}
