import 'package:barcode_widget/barcode_widget.dart';
import 'package:besser_bahn/models/bahnbonus.dart';
import 'package:besser_bahn/providers/bahnbonus_provider.dart';
import 'package:flutter_test/flutter_test.dart';

// Shapes follow the kotlinx models of the BahnBonus app 3.8.1
// (api/loyalty, api/benefitsService). No live sample exists without a
// fe_bb_app token, so these pin the field names we read.
void main() {
  final loyaltyJson = {
    'accountNumber': 7081411234567890,
    'pvNumber': null,
    'status': {
      'level': 'silber',
      'expirationDate': '2027-03-31',
      'points': 1650,
      'advisedPoints': 0,
      'expiringPoints': 0,
    },
    'bonus': {
      'points': 4321,
      'expirationDate': '2026-12-31',
      'advisedPoints': 120,
      'expiringPoints': 300,
    },
  };

  test('parses loyalty and builds the scan-and-collect payload', () {
    final l = BbLoyalty.fromJson(loyaltyJson);
    expect(l.accountNumber, '7081411234567890');
    expect(l.level, BbLevel.silber);
    expect(l.status.points, 1650);
    expect(l.bonus.points, 4321);
    expect(l.bonus.expiringPoints, 300);
    expect(l.bonus.expirationDate, DateTime(2026, 12, 31));
    expect(l.cardPayload, 'BB0001661749;7081411234567890');

    final back = BbLoyalty.fromJson(l.toJson());
    expect(back.level, BbLevel.silber);
    expect(back.bonus.expirationDate, l.bonus.expirationDate);
  });

  test('rejects loyalty without member number', () {
    expect(
      () => BbLoyalty.fromJson({'status': {}, 'bonus': {}}),
      throwsFormatException,
    );
  });

  test('next level from program infos', () {
    final o = BahnbonusOverview(
      loyalty: BbLoyalty.fromJson(loyaltyJson),
      levelBorders: BbLevelBorder.listFromJson({
        'levelBorders': [
          {'level': 'platin', 'requiredPoints': 6000},
          {'level': 'silber', 'requiredPoints': 1500},
          {'level': 'gold', 'requiredPoints': 2500},
        ],
      }),
    );
    expect(o.nextLevel?.level, BbLevel.gold);
    expect(o.nextLevel?.missing, 850);
  });

  test('parses a transactions page with cursor', () {
    final page = BbTransactionPage.fromJson({
      'items': [
        {
          'date': '2026-11-02',
          'points': {'bonus': 87, 'status': 87},
          'title': 'Fahrkarte Berlin – Hamburg',
          'details': 'Auftrag 123',
          'earmarked': true,
        },
        {
          'date': '2026-10-20',
          'points': {'bonus': -1500, 'status': 0},
          'title': 'Prämie',
          'details': null,
          'earmarked': false,
        },
      ],
      'after': 'abc',
      'before': null,
    });
    expect(page.items, hasLength(2));
    expect(page.items.first.earmarked, isTrue);
    expect(page.items[1].bonusPoints, -1500);
    expect(page.after, 'abc');
  });

  test('parses swap offers and vouchers', () {
    final offers = BbSwapOffer.listFromJson({
      'items': [
        {
          'id': 'o1',
          'title': '1. Klasse Upgrade',
          'subtitle': 'Einfache Fahrt',
          'imageUrl': 'https://example.org/a.png',
          'points': 1500,
        },
      ],
    });
    expect(offers.single.points, 1500);

    final vouchers = BbDigitalVoucher.listFromJson([
      {
        'id': 'v1',
        'title': 'DB Lounge',
        'teaserTitle': 'Lounge',
        'iconIdentifier': 'lounge',
        'text': 'Zugang zur DB Lounge',
        'partnerLogoUrl': null,
        'vouchers': [
          {
            'id': 'c1',
            'redeemed': false,
            'expirationDate': '2027-01-31T23:59:59+01:00',
            'invalidUntil': null,
            'activeUntil': null,
            'components': [
              {
                'type': 'aztecCode',
                'aztecCode': {'payload': 'XYZ123', 'displayIdentifier': null},
              },
              {
                'type': 'alphanumericCode',
                'alphanumericCode': {
                  'payload': 'ABCD-1234',
                  'displayIdentifier': 'Code',
                },
              },
            ],
          },
          {'id': 'c2', 'redeemed': true, 'components': []},
        ],
        'additionalInformations': [
          {'title': 'Bedingungen', 'content': '<p>Gilt einmal.</p>'},
        ],
      },
    ], statusBenefit: true);
    final v = vouchers.single;
    expect(v.statusBenefit, isTrue);
    expect(v.openCount, 1);
    expect(v.vouchers.first.components.first.aztec, 'XYZ123');
    expect(v.vouchers.first.components[1].code, 'ABCD-1234');
    expect(v.infoPages.single.title, 'Bedingungen');
  });

  test('card payload encodes as Aztec', () {
    final l = BbLoyalty.fromJson(loyaltyJson);
    expect(Barcode.aztec().isValid(l.cardPayload), isTrue);
    expect(
      Barcode.aztec().make(l.cardPayload, width: 100, height: 100),
      isNotEmpty,
    );
  });
}
