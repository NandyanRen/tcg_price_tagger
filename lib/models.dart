import 'dart:ui' show Offset;

enum Game { onePiece, digimon, riftbound }

extension GameX on Game {
  String get label => switch (this) {
        Game.onePiece => 'One Piece',
        Game.digimon => 'Digimon',
        Game.riftbound => 'Riftbound',
      };

  String get sourceName => switch (this) {
        Game.onePiece || Game.digimon => 'Yuyu-tei',
        Game.riftbound => 'TCGplayer',
      };

  /// Game path on yuyu-tei.jp (null if not priced from Yuyu-tei).
  String? get yuyuteiSlug => switch (this) {
        Game.onePiece => 'opc',
        Game.digimon => 'digi',
        Game.riftbound => null,
      };

  String get searchHint => switch (this) {
        Game.onePiece => 'Card code (EB05-061) or set (EB05)',
        Game.digimon => 'Card code (BT23-075) or set (BT23)',
        Game.riftbound => 'Card name or number (e.g. Noxus Hopeful)',
      };
}

/// A price found at a source (Yuyu-tei in JPY, TCGplayer in USD).
class PriceResult {
  final Game game;
  final String code;
  final String name;
  final String rarity;
  final String variant; // e.g. "Normal" / "Foil" (TCGplayer), empty for Yuyu-tei
  final double sourcePrice;
  final String currency; // 'JPY' or 'USD'
  final String sourceUrl;

  /// Picture of this exact print on the price site (may be empty).
  final String imageUrl;

  const PriceResult({
    required this.game,
    required this.code,
    required this.name,
    required this.rarity,
    this.variant = '',
    required this.sourcePrice,
    required this.currency,
    required this.sourceUrl,
    this.imageUrl = '',
  });

  Map<String, dynamic> toJson() => {
        'game': game.name,
        'code': code,
        'name': name,
        'rarity': rarity,
        'variant': variant,
        'sourcePrice': sourcePrice,
        'currency': currency,
        'sourceUrl': sourceUrl,
        'imageUrl': imageUrl,
      };

  factory PriceResult.fromJson(Map<String, dynamic> j) => PriceResult(
        game: Game.values.byName(j['game'] as String),
        code: j['code'] as String? ?? '',
        name: j['name'] as String? ?? '',
        rarity: j['rarity'] as String? ?? '',
        variant: j['variant'] as String? ?? '',
        sourcePrice: (j['sourcePrice'] as num).toDouble(),
        currency: j['currency'] as String,
        sourceUrl: j['sourceUrl'] as String? ?? '',
        imageUrl: j['imageUrl'] as String? ?? '',
      );
}

/// A price tag placed on the photo.
class PriceTag {
  final String id;

  /// Center of the tag, normalized to the image (0..1 on each axis),
  /// so it lands in the same place on screen and in the exported file.
  Offset pos;

  /// Null when auto-detect couldn't find a price (shown as "₱?").
  int? pricePhp;
  int qty;
  String cardName;
  String code;
  String rarity;

  /// The source price this tag was computed from, kept so tags can be
  /// recalculated when you change the multiplier or exchange rate.
  /// Null when the price was typed in by hand.
  PriceResult? source;

  /// Set on tags placed by auto-detect until you open and save them.
  bool needsReview;

  /// What auto-detect read for this pile, and the top card's size
  /// (normalized). Used to learn from your corrections.
  String readName;
  String readCode;
  double readW, readH;

  PriceTag({
    required this.id,
    required this.pos,
    required this.pricePhp,
    this.qty = 1,
    this.cardName = '',
    this.code = '',
    this.rarity = '',
    this.source,
    this.needsReview = false,
    this.readName = '',
    this.readCode = '',
    this.readW = 0,
    this.readH = 0,
  });

  bool get wasAutoDetected => readName.isNotEmpty || readCode.isNotEmpty;
}
