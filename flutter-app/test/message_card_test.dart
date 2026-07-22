import 'package:besser_bahn/theme/app_colors.dart';
import 'package:besser_bahn/widgets/ui/message_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<MessageCard> _pump(WidgetTester tester, MessageCard card) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: card)));
  return card;
}

void main() {
  group('#38 — one shared shape for every message block', () {
    testWidgets('title and body both render', (tester) async {
      await _pump(
        tester,
        const MessageCard(
          tone: MessageTone.alert,
          title: 'Diese Verbindung fällt aus',
          body: 'Mindestens ein Zug fährt nicht.',
        ),
      );
      expect(find.text('Diese Verbindung fällt aus'), findsOneWidget);
      expect(find.text('Mindestens ein Zug fährt nicht.'), findsOneWidget);
    });

    testWidgets('a note needs no title', (tester) async {
      await _pump(tester, const MessageCard(body: 'Nur ein Hinweis.'));
      expect(find.text('Nur ein Hinweis.'), findsOneWidget);
    });

    testWidgets('the tone picks the accent, and info stays quiet',
        (tester) async {
      // The point of the shared card: colour comes from what the message IS,
      // so a note can't end up as loud as a cancellation.
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const Scaffold(body: SizedBox());
        }),
      ));
      final scheme = Theme.of(ctx).colorScheme;
      expect(const MessageCard(body: 'x', tone: MessageTone.info).accentOf(ctx),
          scheme.outline);
      expect(
          const MessageCard(body: 'x', tone: MessageTone.caution).accentOf(ctx),
          AppColors.warning);
      expect(const MessageCard(body: 'x', tone: MessageTone.alert).accentOf(ctx),
          scheme.error);
      expect(
          const MessageCard(body: 'x', tone: MessageTone.recommendation)
              .accentOf(ctx),
          AppColors.onTime);
    });

    testWidgets('a trailing action and a tap both work', (tester) async {
      var tapped = 0, acted = 0;
      await _pump(
        tester,
        MessageCard(
          body: 'Etwas ist passiert.',
          onTap: () => tapped++,
          trailing: TextButton(
            onPressed: () => acted++,
            child: const Text('Erneut'),
          ),
        ),
      );
      await tester.tap(find.text('Erneut'));
      await tester.tap(find.text('Etwas ist passiert.'));
      expect(acted, 1);
      expect(tapped, 1);
    });
  });
}
