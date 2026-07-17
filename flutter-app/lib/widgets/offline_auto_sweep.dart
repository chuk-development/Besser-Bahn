import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/library_provider.dart';
import '../providers/offline_package_provider.dart';

/// Invisible: on app open and on every resume, tops up the offline package of
/// each upcoming saved trip whose package has gone stale — so a rider who
/// opened the app before leaving finds a fresh package without having to open
/// that trip's card first (#45).
///
/// The actual decision stays in [shouldAutoRefresh] (online + within the
/// pre-departure window + stale), so a trip far out or already-fresh is a
/// no-op, and the in-flight guard makes repeated sweeps cheap.
class OfflineAutoSweep extends ConsumerStatefulWidget {
  const OfflineAutoSweep({super.key});

  @override
  ConsumerState<OfflineAutoSweep> createState() => _OfflineAutoSweepState();
}

class _OfflineAutoSweepState extends ConsumerState<OfflineAutoSweep>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sweep());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _sweep();
  }

  void _sweep() {
    if (!mounted) return;
    for (final j in ref.read(libraryProvider).upcomingJourneys) {
      maybeAutoRefreshPackage(ref, j.key, j.journey);
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
