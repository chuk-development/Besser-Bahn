import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Forwards app lifecycle changes to a callback without the host having to
/// mix in [WidgetsBindingObserver] itself.
class _LifecycleProxy with WidgetsBindingObserver {
  final void Function(AppLifecycleState) onChange;
  _LifecycleProxy(this.onChange);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => onChange(state);
}

/// Drop-in silent auto-refresh for a screen's [ConsumerState].
///
/// While the screen is visible (and the app is in the foreground) it calls
/// [onAutoRefresh] every [autoRefreshInterval]. It also fires once when the
/// screen first shows, again whenever the app returns to the foreground, and
/// again when the rider comes back to a tab it was parked on — so coming back
/// to the screen shows fresh data without a manual pull.
///
/// The implementation of [onAutoRefresh] is expected to fetch *silently*: no
/// loading spinner, and on failure (offline etc.) keep the previously shown
/// data instead of wiping it. The timer is paused while the app is backgrounded
/// so a hidden process never fetches.
///
/// **"Visible" is read off [TickerMode], not off being mounted.** The tab shell
/// is a pager that keeps all four tabs alive at once (`router/tab_pager.dart`),
/// so leaving a tab no longer disposes this State. The pager switches tickers
/// off for every tab but the current one, and this mixin follows that same
/// flag: a parked tab stops polling, and a tab that is only panned over on the
/// way to another one never fetches at all.
mixin AutoRefreshMixin<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  Timer? _timer;
  _LifecycleProxy? _lifecycle;
  ValueListenable<TickerModeData>? _visible;
  bool _foreground = true;

  /// A refresh is owed the next time the screen becomes visible — on mount
  /// (when [refreshOnStart]) and after every stretch spent parked.
  late bool _stale = refreshOnStart;

  /// How often to refresh while the screen is visible. 60s suits live delay
  /// data without hammering the upstream API.
  Duration get autoRefreshInterval => const Duration(seconds: 60);

  /// Whether to fire one refresh immediately on mount.
  bool get refreshOnStart => true;

  /// Fetch fresh data silently. Must keep old data on error.
  Future<void> onAutoRefresh();

  @override
  void initState() {
    super.initState();
    _lifecycle = _LifecycleProxy(_onLifecycle);
    WidgetsBinding.instance.addObserver(_lifecycle!);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.getValuesNotifier(context);
    if (identical(visible, _visible)) return;
    _visible?.removeListener(_onVisibility);
    _visible = visible..addListener(_onVisibility);
    _onVisibility();
  }

  bool get _active => _foreground && (_visible?.value.enabled ?? true);

  /// The TickerMode flag flips during the pager's build, and a refresh writes
  /// providers — which may not happen mid-build. So act after the frame.
  void _onVisibility() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync();
    });
  }

  void _sync() {
    if (!_active) {
      if (_timer != null) _stale = true;
      _timer?.cancel();
      _timer = null;
      return;
    }
    if (_timer != null) return;
    if (_stale) {
      _stale = false;
      onAutoRefresh();
    }
    _timer = Timer.periodic(autoRefreshInterval, (_) {
      if (mounted) onAutoRefresh();
    });
  }

  void _onLifecycle(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      // Returning to the app always refreshes the visible screen; the cadence
      // restarts from the moment of return.
      _stale = true;
      _timer?.cancel();
      _timer = null;
      if (mounted) _sync();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _foreground = false;
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _visible?.removeListener(_onVisibility);
    if (_lifecycle != null) {
      WidgetsBinding.instance.removeObserver(_lifecycle!);
    }
    super.dispose();
  }
}
