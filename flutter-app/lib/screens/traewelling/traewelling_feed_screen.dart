import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/traewelling_models.dart';
import '../../providers/service_providers.dart';
import '../../providers/traewelling_provider.dart';
import '../../widgets/trwl_status_card.dart';
import '../../widgets/app_nav_bar.dart';

/// Which set of check-ins the Feed tab shows.
enum _FeedSource { friends, global, mine }

/// The Feed: switch between people you follow ("Freunde"), the public feed
/// ("Global"), and your own check-ins ("Meine"). Default to your own when you
/// follow no one yet, so the tab is never just an empty box.
class TraewellingFeedScreen extends ConsumerStatefulWidget {
  const TraewellingFeedScreen({super.key});

  @override
  ConsumerState<TraewellingFeedScreen> createState() =>
      _TraewellingFeedScreenState();
}

class _TraewellingFeedScreenState extends ConsumerState<TraewellingFeedScreen> {
  _FeedSource _source = _FeedSource.friends;

  AsyncValue<List<TrwlStatus>> _watch(String? username) {
    switch (_source) {
      case _FeedSource.friends:
        return ref.watch(trwlDashboardProvider);
      case _FeedSource.global:
        return ref.watch(trwlGlobalFeedProvider);
      case _FeedSource.mine:
        return username == null
            ? const AsyncValue.data(<TrwlStatus>[])
            : ref.watch(trwlUserStatusesProvider(username));
    }
  }

  void _refresh(String? username) {
    switch (_source) {
      case _FeedSource.friends:
        ref.invalidate(trwlDashboardProvider);
      case _FeedSource.global:
        ref.invalidate(trwlGlobalFeedProvider);
      case _FeedSource.mine:
        if (username != null) {
          ref.invalidate(trwlUserStatusesProvider(username));
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final username = ref.watch(traewellingAuthProvider).user?.username;
    final feed = _watch(username);

    return Scaffold(
      appBar: AppBar(title: const Text('Feed')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: SegmentedButton<_FeedSource>(
              segments: const [
                ButtonSegment(
                  value: _FeedSource.friends,
                  label: Text('Freunde'),
                  icon: Icon(Icons.group, size: 18),
                ),
                ButtonSegment(
                  value: _FeedSource.global,
                  label: Text('Global'),
                  icon: Icon(Icons.public, size: 18),
                ),
                ButtonSegment(
                  value: _FeedSource.mine,
                  label: Text('Meine'),
                  icon: Icon(Icons.person, size: 18),
                ),
              ],
              selected: {_source},
              onSelectionChanged: (s) => setState(() => _source = s.first),
            ),
          ),
          Expanded(
            child: feed.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => _error(context, username),
              data: (statuses) => RefreshIndicator(
                onRefresh: () async => _refresh(username),
                child: statuses.isEmpty
                    ? _empty(theme)
                    : ListView.builder(
                        padding: EdgeInsets.only(
                          top: 8,
                          bottom: 8 + AppNavBar.insetOf(context),
                        ),
                        itemCount: statuses.length,
                        itemBuilder: (context, i) {
                          final s = statuses[i];
                          return TrwlStatusCard(
                            status: s,
                            onLike: s.isLikable
                                ? () => _toggleLike(s.id, s.liked, username)
                                : null,
                          );
                        },
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty(ThemeData theme) {
    final (text, _) = switch (_source) {
      _FeedSource.friends => (
        'Noch nichts im Feed.\nFolge Leuten oder schau dir „Global" an.',
        null,
      ),
      _FeedSource.global => ('Gerade keine Check-ins.', null),
      _FeedSource.mine => (
        'Noch keine eigenen Fahrten.\nChecke im Zug über das Träwelling-Symbol ein.',
        null,
      ),
    };
    return ListView(
      children: [
        const SizedBox(height: 120),
        Icon(Icons.inbox, size: 56, color: theme.colorScheme.outline),
        const SizedBox(height: 12),
        Center(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.outline),
          ),
        ),
      ],
    );
  }

  Future<void> _toggleLike(int statusId, bool liked, String? username) async {
    final service = ref.read(traewellingServiceProvider);
    try {
      if (liked) {
        await service.unlike(statusId);
      } else {
        await service.like(statusId);
      }
      _refresh(username);
    } catch (_) {
      /* ignore — UI refreshes on next pull */
    }
  }

  Widget _error(BuildContext context, String? username) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 48),
          const SizedBox(height: 12),
          const Text(
            'Feed konnte nicht geladen werden.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => _refresh(username),
            child: const Text('Erneut versuchen'),
          ),
        ],
      ),
    ),
  );
}
