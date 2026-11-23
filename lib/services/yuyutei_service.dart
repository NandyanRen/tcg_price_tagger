import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../debug_log.dart';
import '../models.dart';
import 'auto_pricer.dart' show nameScore;

/// Looks up card prices on Yuyu-tei's selling pages, e.g.
/// https://yuyu-tei.jp/sell/opc/s/eb05 (One Piece)
/// https://yuyu-tei.jp/sell/digi/s/bt23 (Digimon)
class YuyuteiService {
  YuyuteiService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  final Map<String, ({DateTime at, List<PriceResult> cards})> _cache = {};
  static const _cacheTtl = Duration(minutes: 30);

  static final _cardCodeRe = RegExp(r'^([A-Z]{1,4}\d{0,2})-(\d{3})$');
  static final _setCodeRe = RegExp(r'^[A-Z]{1,4}\d{2}$');

  static String setUrl(Game game, String setCode) =>
      'https://yuyu-tei.jp/sell/${game.yuyuteiSlug}/s/${setCode.toLowerCase()}';

  /// Normalizes "bt23 - 075", "BT23‐075" etc. to "BT23-075".
  static String normalizeCode(String raw) => raw
      .trim()
      .toUpperCase()
      .replaceAll(RegExp(r'[\s]'), '')
      .replaceAll(RegExp(r'[‐‑–—ー－]'), '-');

  /// Set part of a card code: "BT23-075" -> "BT23". Null if not a code.
  static String? setOf(String code) =>
      _cardCodeRe.firstMatch(normalizeCode(code))?.group(1);

  /// [query] can be a card code ("EB05-061"), a set code ("EB05"),
  /// or a set code plus a name ("EB05 ナミ").
  Future<List<PriceResult>> lookup(Game game, String query) async {
    final setAndName =
        RegExp(r'^\s*([A-Za-z]{1,4}\d{2})-?\s+(.+)$').firstMatch(query);
    if (setAndName != null &&
        !RegExp(r'^[-\s]*\d{3}$').hasMatch(setAndName.group(2)!)) {
      final cards = await fetchSet(game, setAndName.group(1)!.toUpperCase());
      final name = setAndName.group(2)!.trim();
      final scored = [
        for (final c in cards)
          if (nameScore(c.name, name) >= 0.5) (c, nameScore(c.name, name)),
      ]..sort((a, b) => b.$2.compareTo(a.$2));
      return scored.map((e) => e.$1).toList();
    }
    final q = normalizeCode(query);
    final card = _cardCodeRe.firstMatch(q);
    if (card != null) {
      // The set page plus Yuyu-tei's search by number, which also finds
      // promo-pack and SP prints listed under other pages.
      final results = await Future.wait([
        fetchSet(game, card.group(1)!)
            .then((cards) => cards.where((c) => c.code == q).toList())
            .catchError((_) => <PriceResult>[]),
        searchCode(game, q),
      ]);
      final seen = <String>{};
      return [
        for (final c in [...results[0], ...results[1]])
          if (seen.add('${c.rarity}|${c.name}|${c.sourcePrice}')) c,
      ];
    }
    if (_setCodeRe.hasMatch(q)) {
      return fetchSet(game, q);
    }
    throw FormatException(
        'Type a card code like ${game == Game.digimon ? 'BT23-075' : 'EB05-061'} '
        'or a set code like ${game == Game.digimon ? 'BT23' : 'EB05'}.');
  }

  Future<List<PriceResult>> fetchSet(Game game, String setCode) async {
    if (game.yuyuteiSlug == null) {
      throw ArgumentError('${game.label} is not priced from Yuyu-tei');
    }
    final url = setUrl(game, setCode);
    final cards = await _fetchPage(game, url, setCode.toLowerCase());
    if (cards.isEmpty) {
      throw Exception(
          'No cards found on $url. The page layout may have changed.');
    }
    return cards;
  }

  /// Yuyu-tei's search by card number. Finds every print of that number in
  /// any set, including promo pack and SP versions that aren't on the
  /// number's own set page. Only results with exactly [code] are returned
  /// (the search page also shows unrelated "pickup" and "newest" cards).
  Future<List<PriceResult>> searchCode(Game game, String code) async {
    final slug = game.yuyuteiSlug;
    if (slug == null) return const [];
    final c = normalizeCode(code);
    if (!_cardCodeRe.hasMatch(c)) return const [];
    final url = 'https://yuyu-tei.jp/sell/$slug/s/search'
        '?search_word=${Uri.encodeQueryComponent(c)}';
    try {
      final cards = await _fetchPage(game, url, 'search_$c');
      return cards.where((x) => x.code == c).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<PriceResult>> _fetchPage(
      Game game, String url, String debugName) async {
    final cached = _cache[url];
    if (cached != null && DateTime.now().difference(cached.at) < _cacheTtl) {
      return cached.cards;
    }
    final res = await _client.get(Uri.parse(url), headers: {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/130.0 Safari/537.36',
      'Accept-Language': 'ja,en;q=0.8',
    });
    if (res.statusCode == 404) {
      throw Exception('Yuyu-tei has no page at $url.');
    }
    if (res.statusCode != 200) {
      throw Exception('Yuyu-tei returned HTTP ${res.statusCode}.');
    }
    DebugLog.text('yuyutei_$debugName.html', res.body);
    final cards = parseYuyuteiHtml(res.body, url, game: game);
    DebugLog.text(
        'yuyutei_${debugName}_parsed.tsv',
        cards
            .map((c) =>
                [c.code, c.rarity, c.name, c.sourcePrice, c.imageUrl].join('\t'))
            .join('\n'));
    _cache[url] = (at: DateTime.now(), cards: cards);
    return cards;
  }
}

final _codeTextRe = RegExp(r'^[A-Z]{1,4}\d{0,2}-\d{3}$');
final _yenRe = RegExp(r'([\d,]+)\s*円');

/// Parses a Yuyu-tei set page into prices.
///
/// The parser avoids relying on exact class names: it finds leaf elements
/// whose text is a card code, climbs to the smallest ancestor that also
/// holds a "N円" price (the card box), and takes the rarity from the
/// nearest section heading (h2/h3) before the box in document order.
/// The same code can appear more than once (regular and parallel).
List<PriceResult> parseYuyuteiHtml(String htmlText, String sourceUrl,
    {Game game = Game.onePiece}) {
  final doc = html_parser.parse(htmlText);
  final body = doc.body;
  if (body == null) return [];

  bool isCodeLeaf(Element e) =>
      e.children.isEmpty && _codeTextRe.hasMatch(e.text.trim());

  // 1. Find card boxes.
  final boxes = <Element, String>{}; // box -> code
  for (final el in body.querySelectorAll('*')) {
    if (!isCodeLeaf(el)) continue;
    Element? box = el.parent;
    while (box != null && !_yenRe.hasMatch(box.text)) {
      box = box.parent;
    }
    if (box == null || boxes.containsKey(box)) continue;
    final codesInBox = box.querySelectorAll('*').where(isCodeLeaf).length;
    if (codesInBox != 1) continue; // climbed past a single card
    boxes[box] = el.text.trim();
  }

  // 2. Walk the document in order so each box gets its section's rarity.
  final results = <PriceResult>[];
  var currentRarity = '';

  void visit(Element e) {
    final tag = e.localName;
    if ((tag == 'h2' || tag == 'h3') && !boxes.containsKey(e)) {
      // Headings look like "SEC Card List" / "P-SR カードリスト": keep "SEC".
      final t = e.text
          .trim()
          .replaceAll(RegExp(r'\s+'), ' ')
          .replaceAll(RegExp(r'\s*(card\s*list|カードリスト).*$', caseSensitive: false), '')
          .trim();
      if (t.isNotEmpty && t.length <= 16) currentRarity = t.split(' ').first;
    }
    final code = boxes[e];
    if (code != null) {
      final price =
          int.parse(_yenRe.firstMatch(e.text)!.group(1)!.replaceAll(',', ''));
      results.add(PriceResult(
        game: game,
        code: code,
        name: _cardName(e),
        rarity: currentRarity,
        sourcePrice: price.toDouble(),
        currency: 'JPY',
        sourceUrl: sourceUrl,
        imageUrl: _imageUrl(e, sourceUrl),
      ));
      return; // don't descend into the card box
    }
    for (final c in e.children) {
      visit(c);
    }
  }

  visit(body);
  return results;
}

/// The card picture in a box. The box also holds a ☆ favorite icon (SVG),
/// so prefer <img class="card"> or an image on card.yuyu-tei.jp, and never
/// return a non-photo image.
String _imageUrl(Element box, String pageUrl) {
  String? srcOf(Element im) => [
        im.attributes['data-src'],
        im.attributes['data-original'],
        im.attributes['src'],
      ].firstWhere(
        (v) => v != null && v.isNotEmpty && !v.startsWith('data:'),
        orElse: () => null,
      );
  bool isPhoto(String src) =>
      RegExp(r'\.(jpe?g|png|webp)(\?|$)', caseSensitive: false).hasMatch(src);

  final imgs = box.querySelectorAll('img');
  final ordered = [
    ...imgs.where((im) => im.classes.contains('card')),
    ...imgs.where((im) => (srcOf(im) ?? '').contains('card.yuyu-tei.jp')),
    ...imgs,
  ];
  for (final im in ordered) {
    final src = srcOf(im);
    if (src == null || !isPhoto(src)) continue;
    try {
      return Uri.parse(pageUrl).resolve(src).toString();
    } catch (_) {}
  }
  return '';
}

String _cardName(Element box) {
  for (final sel in ['h4', 'h5', '.card-name', 'p.name']) {
    final t = box.querySelector(sel)?.text.trim();
    if (t != null && t.isNotEmpty) return t;
  }
  final alt = box.querySelector('img[alt]')?.attributes['alt']?.trim();
  if (alt != null && alt.isNotEmpty) {
    // Alt text is often "EB05-061 SEC ナミ"; drop the code and rarity.
    return alt
        .replaceFirst(RegExp(r'^[A-Z]{1,4}\d{0,2}-\d{3}\s*'), '')
        .replaceFirst(RegExp(r'^(P-)?[A-Z]{1,4}\s+'), '')
        .trim();
  }
  return '';
}
