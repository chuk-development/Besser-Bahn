/// BahnBonus programme data from the official BahnBonus app's backend
/// (`apis.deutschebahn.com/db/apis/bahnbonus/*`, `fe_bb_app` bearer).
///
/// Field names mirror the app's kotlinx-serialization models
/// (`com.deutschebahn.bahnbonus` 3.8.1, `api/loyalty`, `api/benefitsService`).
/// Parsing is lenient on purpose: a missing optional field must not hide the
/// whole BahnBonus screen.
library;

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

String? _str(Object? v) {
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

DateTime? _date(Object? v) {
  final s = _str(v);
  return s == null ? null : DateTime.tryParse(s);
}

List<Map<String, dynamic>> _maps(Object? v) =>
    (v is List ? v : const []).whereType<Map<String, dynamic>>().toList();

/// BahnBonus status tiers as the loyalty service names them.
enum BbLevel {
  none('Blau'),
  silber('Silber'),
  gold('Gold'),
  platin('Platin');

  const BbLevel(this.label);
  final String label;

  static BbLevel parse(Object? raw) => switch ('$raw'.toLowerCase()) {
    'silber' || 'silver' => BbLevel.silber,
    'gold' => BbLevel.gold,
    'platin' || 'platinum' => BbLevel.platin,
    _ => BbLevel.none,
  };

  String get wire => switch (this) {
    BbLevel.none => 'noLevel',
    BbLevel.silber => 'silber',
    BbLevel.gold => 'gold',
    BbLevel.platin => 'platin',
  };
}

/// One points pot: Prämienpunkte (`bonus`) or Statuspunkte (`status`).
class BbPoints {
  final int points;

  /// Points that run out on [expirationDate] unless used.
  final int expiringPoints;

  /// Points earned but not yet credited ("vorgemerkt").
  final int advisedPoints;
  final DateTime? expirationDate;

  const BbPoints({
    required this.points,
    required this.expiringPoints,
    required this.advisedPoints,
    this.expirationDate,
  });

  factory BbPoints.fromJson(Map<String, dynamic> j) => BbPoints(
    points: _int(j['points']),
    expiringPoints: _int(j['expiringPoints']),
    advisedPoints: _int(j['advisedPoints']),
    expirationDate: _date(j['expirationDate']),
  );

  Map<String, dynamic> toJson() => {
    'points': points,
    'expiringPoints': expiringPoints,
    'advisedPoints': advisedPoints,
    if (expirationDate != null)
      'expirationDate': expirationDate!.toIso8601String().split('T').first,
  };
}

/// `GET loyalty-service/v3/customer/loyalty`.
class BbLoyalty {
  /// BahnBonus member number. The digital card encodes it.
  final String accountNumber;
  final BbLevel level;
  final BbPoints status;
  final BbPoints bonus;

  const BbLoyalty({
    required this.accountNumber,
    required this.level,
    required this.status,
    required this.bonus,
  });

  /// Aztec payload of the digital BahnBonus card, exactly as the official
  /// app builds it (`ScanAndCollectPointsViewModel`). Partners and DB travel
  /// centres scan it to credit points.
  String get cardPayload => 'BB0001661749;$accountNumber';

  factory BbLoyalty.fromJson(Map<String, dynamic> j) {
    final status = j['status'];
    final bonus = j['bonus'];
    final number = _str(j['accountNumber']);
    if (number == null ||
        status is! Map<String, dynamic> ||
        bonus is! Map<String, dynamic>) {
      throw const FormatException('loyalty: accountNumber/status/bonus fehlt');
    }
    return BbLoyalty(
      accountNumber: number,
      level: BbLevel.parse(status['level']),
      status: BbPoints.fromJson(status),
      bonus: BbPoints.fromJson(bonus),
    );
  }

  Map<String, dynamic> toJson() => {
    'accountNumber': accountNumber,
    'status': {...status.toJson(), 'level': level.wire},
    'bonus': bonus.toJson(),
  };
}

/// `GET loyalty-service/v2/program-infos` → status points needed per tier.
class BbLevelBorder {
  final BbLevel level;
  final int requiredPoints;
  const BbLevelBorder(this.level, this.requiredPoints);

  static List<BbLevelBorder> listFromJson(Map<String, dynamic> j) =>
      _maps(j['levelBorders'])
          .map(
            (b) => BbLevelBorder(
              BbLevel.parse(b['level']),
              _int(b['requiredPoints']),
            ),
          )
          .toList()
        ..sort((a, b) => a.requiredPoints.compareTo(b.requiredPoints));

  Map<String, dynamic> toJson() => {
    'level': level.wire,
    'requiredPoints': requiredPoints,
  };
}

/// Which points history to read (`type` query of the transactions call).
enum BbPointsType { bonus, status }

/// One booking in the points history.
class BbTransaction {
  final DateTime? date;
  final int bonusPoints;
  final int statusPoints;
  final String title;
  final String? details;

  /// Booked but not yet credited ("vorgemerkt").
  final bool earmarked;

  const BbTransaction({
    required this.date,
    required this.bonusPoints,
    required this.statusPoints,
    required this.title,
    this.details,
    this.earmarked = false,
  });

  factory BbTransaction.fromJson(Map<String, dynamic> j) {
    final pts = j['points'];
    final m = pts is Map<String, dynamic> ? pts : const <String, dynamic>{};
    return BbTransaction(
      date: _date(j['date']),
      bonusPoints: _int(m['bonus']),
      statusPoints: _int(m['status']),
      title: _str(j['title']) ?? 'Buchung',
      details: _str(j['details']),
      earmarked: j['earmarked'] == true,
    );
  }
}

/// One page of `GET loyalty-service/v3/customer/transactions`. [after] is
/// the cursor for the next (older) page; null means the end.
class BbTransactionPage {
  final List<BbTransaction> items;
  final String? after;
  const BbTransactionPage(this.items, this.after);

  factory BbTransactionPage.fromJson(Map<String, dynamic> j) =>
      BbTransactionPage(
        _maps(j['items']).map(BbTransaction.fromJson).toList(),
        _str(j['after']),
      );
}

/// A "Prämie gegen Punkte" offer the app redeems directly
/// (`GET/POST benefits-service/v1/swap-offers`).
class BbSwapOffer {
  final String id;
  final String title;
  final String? subtitle;
  final String? imageUrl;
  final int points;

  const BbSwapOffer({
    required this.id,
    required this.title,
    required this.points,
    this.subtitle,
    this.imageUrl,
  });

  static List<BbSwapOffer> listFromJson(Map<String, dynamic> j) =>
      _maps(j['items'])
          .map(
            (o) => BbSwapOffer(
              id: '${o['id']}',
              title: _str(o['title']) ?? 'Prämie',
              subtitle: _str(o['subtitle']),
              imageUrl: _str(o['imageUrl']),
              points: _int(o['points']),
            ),
          )
          .where((o) => o.id.isNotEmpty && o.id != 'null')
          .toList();
}

/// A code inside a voucher: plain text, an Aztec code, a text block or a
/// link. Mirrors `VoucherComponent`.
class BbVoucherComponent {
  final String type;
  final String? code; // alphanumericCode.payload
  final String? codeLabel; // alphanumericCode.displayIdentifier
  final String? aztec; // aztecCode.payload
  final String? information;
  final String? actionTitle;
  final String? actionUri;
  final String? bahncard100Title;
  final String? bahncard100Text;

  const BbVoucherComponent({
    required this.type,
    this.code,
    this.codeLabel,
    this.aztec,
    this.information,
    this.actionTitle,
    this.actionUri,
    this.bahncard100Title,
    this.bahncard100Text,
  });

  factory BbVoucherComponent.fromJson(Map<String, dynamic> j) {
    Map<String, dynamic> sub(String k) =>
        j[k] is Map<String, dynamic> ? j[k] as Map<String, dynamic> : const {};
    final alpha = sub('alphanumericCode');
    final aztec = sub('aztecCode');
    final action = sub('action');
    final bc = sub('bahncard100');
    final info = j['information'];
    return BbVoucherComponent(
      type: _str(j['type']) ?? 'unknown',
      code: _str(alpha['payload']),
      codeLabel: _str(alpha['displayIdentifier']),
      aztec: _str(aztec['payload']),
      information: info is Map
          ? _str(info['content'] ?? info['title'])
          : _str(info),
      actionTitle: _str(action['title']),
      actionUri: _str(action['uri']),
      bahncard100Title: _str(bc['title']),
      bahncard100Text: _str(bc['text']),
    );
  }
}

/// One single code of a [BbDigitalVoucher] (a voucher can hold several, e.g.
/// one per lounge visit).
class BbVoucher {
  final String id;
  final bool redeemed;
  final DateTime? expirationDate;
  final DateTime? activeUntil;
  final List<BbVoucherComponent> components;

  const BbVoucher({
    required this.id,
    required this.redeemed,
    required this.components,
    this.expirationDate,
    this.activeUntil,
  });

  factory BbVoucher.fromJson(Map<String, dynamic> j) => BbVoucher(
    id: '${j['id']}',
    redeemed: j['redeemed'] == true,
    expirationDate: _date(j['expirationDate']),
    activeUntil: _date(j['activeUntil']),
    components: _maps(
      j['components'],
    ).map(BbVoucherComponent.fromJson).toList(),
  );
}

/// A digital voucher or status benefit (`benefits-service/v1/digital-vouchers`
/// and `…/status-benefits?partner=Deutsche Bahn`): e.g. lounge access, seat
/// reservation, 1st-class upgrade.
class BbDigitalVoucher {
  final String id;
  final String title;
  final String? text;
  final String? partnerLogoUrl;
  final List<BbVoucher> vouchers;
  final List<({String title, String content})> infoPages;

  /// True for a status benefit (comes with Silber/Gold/Platin), false for a
  /// voucher bought or swapped with points.
  final bool statusBenefit;

  const BbDigitalVoucher({
    required this.id,
    required this.title,
    required this.vouchers,
    this.text,
    this.partnerLogoUrl,
    this.infoPages = const [],
    this.statusBenefit = false,
  });

  int get openCount => vouchers.where((v) => !v.redeemed).length;

  static List<BbDigitalVoucher> listFromJson(
    Object? data, {
    bool statusBenefit = false,
  }) => _maps(data)
      .map(
        (v) => BbDigitalVoucher(
          id: '${v['id']}',
          title: _str(v['title']) ?? _str(v['teaserTitle']) ?? 'Gutschein',
          text: _str(v['text']),
          partnerLogoUrl: _str(v['partnerLogoUrl']),
          vouchers: _maps(v['vouchers']).map(BbVoucher.fromJson).toList(),
          infoPages: _maps(v['additionalInformations'])
              .map(
                (p) => (
                  title: _str(p['title']) ?? '',
                  content: _str(p['content']) ?? '',
                ),
              )
              .where((p) => p.title.isNotEmpty || p.content.isNotEmpty)
              .toList(),
          statusBenefit: statusBenefit,
        ),
      )
      .toList();
}
