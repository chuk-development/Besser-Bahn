import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/traewelling_models.dart';
import '../../providers/service_providers.dart';
import '../../providers/traewelling_provider.dart';
import '../../theme/app_colors.dart';

/// Follower / Following / follow-request management, plus user search to find
/// and follow friends.
class TraewellingFriendsScreen extends ConsumerStatefulWidget {
  const TraewellingFriendsScreen({super.key});

  @override
  ConsumerState<TraewellingFriendsScreen> createState() =>
      _TraewellingFriendsScreenState();
}

class _TraewellingFriendsScreenState
    extends ConsumerState<TraewellingFriendsScreen> {
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Freunde'),
          actions: [
            IconButton(
              icon: const Icon(Icons.person_search),
              tooltip: 'Suchen',
              onPressed: () => showSearch(
                  context: context, delegate: _UserSearchDelegate(ref)),
            ),
          ],
          bottom: const TabBar(tabs: [
            Tab(text: 'Following'),
            Tab(text: 'Follower'),
            Tab(text: 'Anfragen'),
          ]),
        ),
        body: TabBarView(
          children: [
            _UserList(
              provider: trwlFollowingsProvider,
              emptyText: 'Du folgst noch niemandem.',
            ),
            _UserList(
              provider: trwlFollowersProvider,
              emptyText: 'Noch keine Follower.',
            ),
            _RequestsList(),
          ],
        ),
      ),
    );
  }
}

class _UserList extends ConsumerWidget {
  final FutureProvider<List<TrwlUser>> provider;
  final String emptyText;
  const _UserList({required this.provider, required this.emptyText});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(provider);
    return users.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Fehler: $e')),
      data: (list) => list.isEmpty
          ? _empty(context, emptyText)
          : RefreshIndicator(
              onRefresh: () async => ref.invalidate(provider),
              child: ListView.builder(
                itemCount: list.length,
                itemBuilder: (c, i) => _UserTile(user: list[i]),
              ),
            ),
    );
  }
}

class _RequestsList extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reqs = ref.watch(trwlFollowRequestsProvider);
    final service = ref.read(traewellingServiceProvider);
    return reqs.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Fehler: $e')),
      data: (list) => list.isEmpty
          ? _empty(context, 'Keine offenen Anfragen.')
          : ListView.builder(
              itemCount: list.length,
              itemBuilder: (c, i) {
                final u = list[i];
                return ListTile(
                  leading: _avatar(context, u),
                  title: Text(u.displayName),
                  subtitle: Text('@${u.username}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.check_circle,
                            color: AppColors.onTime),
                        tooltip: 'Annehmen',
                        onPressed: () async {
                          await service.approveFollowRequest(u.id);
                          ref.invalidate(trwlFollowRequestsProvider);
                          ref.invalidate(trwlFollowersProvider);
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.cancel,
                            color: AppColors.cancelled),
                        tooltip: 'Ablehnen',
                        onPressed: () async {
                          await service.rejectFollowRequest(u.id);
                          ref.invalidate(trwlFollowRequestsProvider);
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

/// A user row with a follow/unfollow toggle.
class _UserTile extends ConsumerStatefulWidget {
  final TrwlUser user;
  const _UserTile({required this.user});

  @override
  ConsumerState<_UserTile> createState() => _UserTileState();
}

class _UserTileState extends ConsumerState<_UserTile> {
  late bool _following = widget.user.following;
  late bool _pending = widget.user.followPending;
  bool _busy = false;

  Future<void> _toggle() async {
    final service = ref.read(traewellingServiceProvider);
    setState(() => _busy = true);
    try {
      if (_following || _pending) {
        await service.unfollow(widget.user.id);
        setState(() {
          _following = false;
          _pending = false;
        });
      } else {
        await service.follow(widget.user.id);
        // Private profiles return a pending request rather than a follow.
        setState(() =>
            widget.user.privateProfile ? _pending = true : _following = true);
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = _pending
        ? 'Angefragt'
        : _following
            ? 'Entfolgen'
            : 'Folgen';
    return ListTile(
      leading: _avatar(context, widget.user),
      title: Text(widget.user.displayName),
      subtitle: Text('@${widget.user.username}'),
      trailing: _busy
          ? const SizedBox(
              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : OutlinedButton(onPressed: _toggle, child: Text(label)),
    );
  }
}

class _UserSearchDelegate extends SearchDelegate<void> {
  final WidgetRef ref;
  _UserSearchDelegate(this.ref) : super(searchFieldLabel: 'Nutzer:in suchen');

  @override
  List<Widget> buildActions(BuildContext context) =>
      [IconButton(icon: const Icon(Icons.clear), onPressed: () => query = '')];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
      icon: const Icon(Icons.arrow_back), onPressed: () => close(context, null));

  @override
  Widget buildSuggestions(BuildContext context) => _results(context);

  @override
  Widget buildResults(BuildContext context) => _results(context);

  Widget _results(BuildContext context) {
    if (query.trim().length < 2) {
      return const Center(child: Text('Mindestens 2 Zeichen eingeben.'));
    }
    return FutureBuilder<List<TrwlUser>>(
      future: ref.read(traewellingServiceProvider).searchUsers(query.trim()),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) return Center(child: Text('Fehler: ${snap.error}'));
        final list = snap.data ?? [];
        if (list.isEmpty) {
          return const Center(child: Text('Keine Treffer.'));
        }
        return ListView(children: list.map((u) => _UserTile(user: u)).toList());
      },
    );
  }
}

Widget _avatar(BuildContext context, TrwlUser u) => CircleAvatar(
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      backgroundImage: (u.profilePicture?.isNotEmpty ?? false)
          ? NetworkImage(u.profilePicture!)
          : null,
      child: (u.profilePicture?.isNotEmpty ?? false)
          ? null
          : Text(u.displayName.isNotEmpty ? u.displayName[0].toUpperCase() : '?'),
    );

Widget _empty(BuildContext context, String text) => ListView(
      children: [
        const SizedBox(height: 120),
        Center(
          child: Text(text,
              style: TextStyle(color: Theme.of(context).colorScheme.outline)),
        ),
      ],
    );
