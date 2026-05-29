import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/traewelling_provider.dart';

/// AppBar entry point for the Träwelling section. Shows the logged-in user's
/// profile picture (or a generic person icon when logged out) and opens the
/// Träwelling hub on tap. Drop into any screen's `AppBar.actions`.
class TraewellingAvatarButton extends ConsumerWidget {
  const TraewellingAvatarButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(traewellingAuthProvider);
    final user = auth.user;
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: IconButton(
        tooltip: 'Träwelling',
        onPressed: () => context.push('/trawelling'),
        icon: CircleAvatar(
          radius: 15,
          backgroundColor: theme.colorScheme.primaryContainer,
          backgroundImage: (user?.profilePicture?.isNotEmpty ?? false)
              ? NetworkImage(user!.profilePicture!)
              : null,
          child: (user?.profilePicture?.isNotEmpty ?? false)
              ? null
              : Icon(Icons.person_outline,
                  size: 18, color: theme.colorScheme.onPrimaryContainer),
        ),
      ),
    );
  }
}
