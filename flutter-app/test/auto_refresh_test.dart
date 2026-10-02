// AutoRefreshMixin polls only while its screen is visible — and since the tab
// shell keeps all four tabs mounted, "visible" is the TickerMode flag the tab
// pager sets, not being mounted. A parked tab must not poll, and a tab that is
// only panned over must not fetch at all.
import 'package:besser_bahn/core/auto_refresh.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Polling extends ConsumerStatefulWidget {
  final List<int> calls;
  const _Polling(this.calls);

  @override
  ConsumerState<_Polling> createState() => _PollingState();
}

class _PollingState extends ConsumerState<_Polling> with AutoRefreshMixin {
  @override
  Duration get autoRefreshInterval => const Duration(seconds: 10);

  @override
  Future<void> onAutoRefresh() async => widget.calls.add(0);

  @override
  Widget build(BuildContext context) => const SizedBox();
}

Widget _host(ValueNotifier<bool> visible, List<int> calls) => ProviderScope(
  child: ValueListenableBuilder<bool>(
    valueListenable: visible,
    builder: (_, on, child) => TickerMode(enabled: on, child: child!),
    child: _Polling(calls),
  ),
);

void main() {
  testWidgets('a visible screen refreshes on mount and then on its cadence', (
    tester,
  ) async {
    final calls = <int>[];
    await tester.pumpWidget(_host(ValueNotifier(true), calls));
    await tester.pump();
    expect(calls, hasLength(1));
    await tester.pump(const Duration(seconds: 10));
    expect(calls, hasLength(2));
  });

  testWidgets('a parked screen neither fetches on mount nor polls', (
    tester,
  ) async {
    final calls = <int>[];
    final visible = ValueNotifier(false);
    await tester.pumpWidget(_host(visible, calls));
    await tester.pump();
    await tester.pump(const Duration(seconds: 35));
    expect(calls, isEmpty);

    // Brought on screen: the owed refresh fires, then the cadence resumes.
    visible.value = true;
    await tester.pump();
    await tester.pump();
    expect(calls, hasLength(1));
    await tester.pump(const Duration(seconds: 10));
    expect(calls, hasLength(2));
  });

  testWidgets('leaving stops polling, coming back refreshes once', (
    tester,
  ) async {
    final calls = <int>[];
    final visible = ValueNotifier(true);
    await tester.pumpWidget(_host(visible, calls));
    await tester.pump();
    expect(calls, hasLength(1));

    visible.value = false;
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 45));
    expect(calls, hasLength(1), reason: 'parked tabs do not poll');

    visible.value = true;
    await tester.pump();
    await tester.pump();
    expect(calls, hasLength(2), reason: 'back on screen = fresh data');
  });
}
