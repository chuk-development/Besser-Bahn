import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/traewelling_models.dart';
import '../theme/app_colors.dart';

/// A single Träwelling check-in rendered as a card — used in the dashboard
/// feed and on profiles. [onLike] is null when liking isn't allowed.
class TrwlStatusCard extends StatelessWidget {
  final TrwlStatus status;
  final VoidCallback? onLike;
  final void Function(String username)? onUserTap;

  const TrwlStatusCard({
    super.key,
    required this.status,
    this.onLike,
    this.onUserTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = status.transport;
    final user = status.user;
    final timeFmt = DateFormat('HH:mm');

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (user != null)
              InkWell(
                onTap: onUserTap == null
                    ? null
                    : () => onUserTap!(user.username),
                child: Row(
                  children: [
                    _Avatar(url: user.profilePicture, name: user.displayName),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(user.displayName,
                              style: theme.textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.bold)),
                          Text('@${user.username}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.outline)),
                        ],
                      ),
                    ),
                    if (status.createdAt != null)
                      Text(_relative(status.createdAt!),
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.outline)),
                  ],
                ),
              ),
            if (t != null) ...[
              const SizedBox(height: 12),
              _TripRow(transport: t, timeFmt: timeFmt),
            ],
            if (status.body.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(status.body, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                if (t != null) ...[
                  Icon(Icons.straighten,
                      size: 15, color: theme.colorScheme.outline),
                  const SizedBox(width: 4),
                  Text('${t.distanceKm.toStringAsFixed(1)} km',
                      style: theme.textTheme.bodySmall),
                  const SizedBox(width: 12),
                  Icon(Icons.timer_outlined,
                      size: 15, color: theme.colorScheme.outline),
                  const SizedBox(width: 4),
                  Text(_duration(t.duration), style: theme.textTheme.bodySmall),
                ],
                const Spacer(),
                if (status.isLikable)
                  InkWell(
                    onTap: onLike,
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      child: Row(
                        children: [
                          Icon(
                            status.liked
                                ? Icons.favorite
                                : Icons.favorite_border,
                            size: 18,
                            color: status.liked ? AppColors.dbRed : null,
                          ),
                          const SizedBox(width: 4),
                          Text('${status.likes}',
                              style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _duration(int minutes) {
    if (minutes < 60) return '$minutes min';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}min';
  }

  static String _relative(DateTime dt) {
    final d = DateTime.now().difference(dt);
    if (d.inMinutes < 1) return 'jetzt';
    if (d.inMinutes < 60) return 'vor ${d.inMinutes} min';
    if (d.inHours < 24) return 'vor ${d.inHours} h';
    if (d.inDays < 7) return 'vor ${d.inDays} d';
    return DateFormat('dd.MM.yy').format(dt);
  }
}

class _TripRow extends StatelessWidget {
  final TrwlTransport transport;
  final DateFormat timeFmt;
  const _TripRow({required this.transport, required this.timeFmt});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final origin = transport.origin;
    final dest = transport.destination;
    Color lineColor = AppColors.dbRed;
    final hex = transport.routeColor;
    if (hex != null && hex.length >= 6) {
      final parsed = int.tryParse(hex.replaceAll('#', ''), radix: 16);
      if (parsed != null) lineColor = Color(0xFF000000 | parsed);
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: lineColor,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(transport.lineName,
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _stop(theme, origin?.name ?? '—',
                  origin?.departure, true),
              const SizedBox(height: 2),
              _stop(theme, dest?.name ?? '—', dest?.arrival, false),
            ],
          ),
        ),
      ],
    );
  }

  Widget _stop(ThemeData theme, String name, DateTime? time, bool isOrigin) {
    return Row(
      children: [
        Icon(isOrigin ? Icons.trip_origin : Icons.place,
            size: 13, color: theme.colorScheme.outline),
        const SizedBox(width: 6),
        Expanded(
          child: Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium),
        ),
        if (time != null)
          Text(timeFmt.format(time.toLocal()),
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _Avatar extends StatelessWidget {
  final String? url;
  final String name;
  const _Avatar({this.url, required this.name});

  @override
  Widget build(BuildContext context) {
    final initials = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return CircleAvatar(
      radius: 18,
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      backgroundImage: (url != null && url!.isNotEmpty)
          ? NetworkImage(url!)
          : null,
      child: (url == null || url!.isEmpty)
          ? Text(initials,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimaryContainer))
          : null,
    );
  }
}
