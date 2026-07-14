import 'package:besser_bahn/models/transfer_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TransferProfile (#11, point 7)', () {
    test('Normal leaves the planned gap untouched', () {
      expect(TransferProfile.normal.effectiveGap(8), 8);
      expect(TransferProfile.normal.factor, 1.0);
    });

    test('the reported case: 8 min is not 8 min for everyone', () {
      // "Dann wäre 8 Minuten Umstieg nicht für alle gleich bewertet."
      expect(TransferProfile.fast.effectiveGap(8), greaterThan(8));
      expect(TransferProfile.normal.effectiveGap(8), 8);
      expect(TransferProfile.child.effectiveGap(8), lessThan(8));
      expect(TransferProfile.accessible.effectiveGap(8), lessThan(8));
    });

    test('a pram turns a comfortable 10 min into a tight one', () {
      // 10 / 1.6 = 6.25 → 6, which is under the "tight" threshold of 5? No —
      // still 6, so it warns as tight-ish but not at-risk. The point is it
      // moves, and monotonically.
      expect(TransferProfile.child.effectiveGap(10), 6);
      expect(TransferProfile.slow.effectiveGap(10), 5);
      expect(TransferProfile.accessible.effectiveGap(10), 5);
    });

    test('slower profiles never judge a gap as roomier than faster ones', () {
      const gap = 12;
      var previous = 1 << 30;
      for (final p in [
        TransferProfile.fast,
        TransferProfile.normal,
        TransferProfile.luggage,
        TransferProfile.child,
        TransferProfile.accessible,
        TransferProfile.slow,
      ]) {
        final felt = p.effectiveGap(gap);
        expect(felt, lessThanOrEqualTo(previous),
            reason: '${p.label} must not feel roomier than the profile before');
        previous = felt;
      }
    });

    test('a negative gap (already too late) stays negative for everyone', () {
      for (final p in TransferProfile.values) {
        expect(p.effectiveGap(-3), lessThan(0),
            reason: '${p.label}: missing by 3 min is missed on any profile');
      }
    });

    test('round-trips through its persisted name', () {
      for (final p in TransferProfile.values) {
        expect(TransferProfile.fromName(p.name), p);
      }
    });

    test('an unknown or absent stored value falls back to Normal', () {
      expect(TransferProfile.fromName(null), TransferProfile.normal);
      expect(TransferProfile.fromName('nonsense'), TransferProfile.normal);
      expect(TransferProfile.fromName(''), TransferProfile.normal);
    });

    test('every profile has a label and a why', () {
      for (final p in TransferProfile.values) {
        expect(p.label, isNotEmpty);
        expect(p.hint, isNotEmpty);
        expect(p.emoji, isNotEmpty);
      }
    });
  });
}
