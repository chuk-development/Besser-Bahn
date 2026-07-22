import 'package:besser_bahn/services/vendo_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _uuid = '918899f1-7080-416f-895a-f336adf7295f';

void main() {
  group('#44 — reading the vbid out of whatever the rider pasted', () {
    test('a bare vbid= assignment', () {
      expect(VendoService.extractVbid('vbid=$_uuid'), _uuid);
    });

    test('the bare UUID on its own', () {
      expect(VendoService.extractVbid(_uuid), _uuid);
    });

    test('the full bahn.de link', () {
      expect(
        VendoService.extractVbid(
            'https://www.bahn.de/buchung/start?vbid=$_uuid'),
        _uuid,
      );
    });

    test('the international link', () {
      expect(
        VendoService.extractVbid(
            'https://int.bahn.de/en/buchung/start?vbid=$_uuid'),
        _uuid,
      );
    });

    test('a whole shared message with the link inside it', () {
      // What you actually get when someone forwards a DB share text.
      const text = '''
Berlin Südkreuz → Elstal
Sa. 18.07.2026

RE4 (3149)
Verbindung ansehen: https://www.bahn.de/buchung/start?vbid=$_uuid
''';
      expect(VendoService.extractVbid(text), _uuid);
    });

    test('surrounding whitespace and a trailing query param', () {
      expect(
        VendoService.extractVbid(
            '  https://www.bahn.de/buchung/start?vbid=$_uuid&lang=de  '),
        _uuid,
      );
    });

    test('nothing usable stays null', () {
      expect(VendoService.extractVbid(''), isNull);
      expect(VendoService.extractVbid('   '), isNull);
      expect(VendoService.extractVbid('hallo, wie gehts?'), isNull);
      expect(VendoService.extractVbid('https://www.bahn.de/'), isNull,
          reason: 'a link without a share id is not a share link');
    });
  });
}
