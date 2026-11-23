import '../models.dart';
import 'card_recognizer.dart';
import 'tcgcsv_service.dart';
import 'yuyutei_service.dart';

/// Picks the best price listing for a pile the recognizer found.
class AutoPricer {
  AutoPricer(this.yuyutei, this.tcgcsv);

  final YuyuteiService yuyutei;
  final TcgCsvService tcgcsv;

  /// Set / page codes in your hint: "eb05, op14" -> ["EB05", "OP14"].
  /// Also accepts Yuyu-tei page names like "promo-op20".
  static List<String> parseSetHint(String text) => _hintParts(text).$1;

  /// Everything else in your hint is a name keyword, e.g. "EX Vol.5"
  /// matches "(プロモーションパックEX Vol.5)" in a listing's name.
  static List<String> parseHintKeywords(String text) => _hintParts(text).$2;

  static (List<String>, List<String>) _hintParts(String text) {
    final sets = <String>{}, words = <String>{};
    final setRe = RegExp(r'^[A-Za-z][A-Za-z0-9-]*\d{2}$');
    for (final part in text.split(RegExp(r'[,;、\n]+'))) {
      final tokens = part.trim().split(RegExp(r'\s+'))
        ..removeWhere((t) => t.isEmpty);
      if (tokens.isEmpty) continue;
      // "EB05 OP14" = two sets; "EX Vol.5" = one keyword phrase.
      if (tokens.every(setRe.hasMatch)) {
        sets.addAll(tokens.map((t) => t.toUpperCase()));
      } else {
        words.add(part.trim());
      }
    }
    return (sets.toList(), words.toList());
  }

  /// Set prefix even from a partial code: "EB05-", "eb05-06" -> "EB05".
  static String? setPrefix(String code) =>
      RegExp(r'^([A-Z]{1,4}\d{2})(?:-|$)')
          .firstMatch(YuyuteiService.normalizeCode(code))
          ?.group(1);

  /// All sets mentioned by any pile in the photo, most common first.
  static List<String> setsInPhoto(List<DetectedPile> piles) {
    final counts = <String, int>{};
    for (final p in piles) {
      final s = setPrefix(p.code);
      if (s != null) counts[s] = (counts[s] ?? 0) + 1;
    }
    final sets = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    return sets.take(4).toList();
  }

  /// Every card in [sets] (failed sets are skipped).
  Future<List<PriceResult>> catalogFor(Game game, List<String> sets) async {
    final all = <PriceResult>[];
    for (final s in sets) {
      try {
        all.addAll(await yuyutei.fetchSet(game, s));
      } catch (_) {}
    }
    return all;
  }

  /// Returns null when no confident match is found.
  Future<PriceResult?> priceFor(
    DetectedPile pile,
    Game game, {
    required String riftboundCategory,
    List<String> hintSets = const [],
    List<String> photoSets = const [],
  }) async {
    if (game == Game.riftbound) {
      final q = pile.name.isNotEmpty ? pile.name : pile.code;
      if (q.isEmpty) return null;
      final hits = await tcgcsv.search(q, riftboundCategory);
      if (hits.isEmpty) return null;
      final wantFoil = pile.parallel;
      return hits.firstWhere(
        (h) => h.variant.toLowerCase().contains('foil') == wantFoil,
        orElse: () => hits.first,
      );
    }

    final code = YuyuteiService.normalizeCode(pile.code);
    // Sets you named come first: SP reprints are listed on the page of the
    // set they came out in, under their original (older) card number.
    final sets = <String>{
      ...hintSets,
      if (setPrefix(code) != null) setPrefix(code)!,
      ...photoSets,
    };

    for (final set in sets) {
      List<PriceResult> setCards;
      try {
        setCards = await yuyutei.fetchSet(game, set);
      } catch (_) {
        continue;
      }
      final match = matchInSet(setCards, code: code, name: pile.name);
      if (match != null) {
        return pickPrint(match, parallel: pile.parallel, sp: pile.sp);
      }
    }
    return null;
  }
}

/// Finds the listings in one set for a card, by code (confirmed by name
/// when there is one) or else by name. Returns all prints of that card.
List<PriceResult>? matchInSet(
  List<PriceResult> setCards, {
  required String code,
  required String name,
}) {
  final byCode = setCards.where((c) => c.code == code).toList();
  if (byCode.isNotEmpty &&
      (name.isEmpty || byCode.any((c) => nameScore(c.name, name) >= 0.6))) {
    return byCode;
  }
  if (name.isEmpty) return byCode.isEmpty ? null : byCode;

  // Code missing or misread: best name match in the set.
  PriceResult? best;
  var bestScore = 0.0;
  for (final c in setCards) {
    final s = nameScore(c.name, name);
    if (s > bestScore) {
      bestScore = s;
      best = c;
    }
  }
  if (best != null && bestScore >= 0.6) {
    // Two different cards with an equally good name (e.g. two "ナミ" in one
    // set) is ambiguous: leave it for the catalog pass instead of guessing.
    final tied = setCards
        .where((c) => c.code != best!.code && nameScore(c.name, name) >= bestScore)
        .isNotEmpty;
    if (tied) return null;
    return setCards.where((c) => c.code == best!.code).toList();
  }
  // The code exists but is a different card than the name says: the code
  // was misread. Don't guess.
  return null;
}

/// Every listing that could be this pile, best first, for the picture
/// check to choose from. Matches mostly by name (codes read through
/// toploaders are unreliable), boosting listings from your set hint, the
/// exact code, and SP/parallel prints when the pile looks like one.
List<PriceResult> candidatesFor(
  DetectedPile pile,
  List<PriceResult> allCards, {
  List<String> hintSets = const [],
  List<String> hintKeywords = const [],
  int limit = 6,
}) {
  final kws = hintKeywords.map(_normLoose).where((k) => k.isNotEmpty).toList();
  final code = YuyuteiService.normalizeCode(pile.code);
  bool inHint(PriceResult c) => hintSets.any(
      (h) => c.sourceUrl.toLowerCase().endsWith('/s/${h.toLowerCase()}'));

  final seen = <String>{};
  final scored = <(PriceResult, double)>[];
  for (final c in allCards) {
    final ns = pile.name.isEmpty ? 0.0 : nameScore(c.name, pile.name);
    final codeHit = code.isNotEmpty && c.code == code;
    if (ns < 0.6 && !(codeHit && pile.name.isEmpty)) continue;
    // The same listing can come from a set page and from search.
    if (!seen.add('${c.code}|${c.rarity}|${c.name}|${c.sourcePrice}')) {
      continue;
    }
    var score = ns;
    if (codeHit) score += 0.3;
    if (inHint(c)) score += 0.5;
    if (kws.isNotEmpty && kws.any(_normLoose(c.name).contains)) score += 0.8;
    if (isSpPrint(c)) score += pile.sp ? 0.4 : -0.2;
    if (isParallelPrint(c) == pile.parallel) score += 0.1;
    scored.add((c, score));
  }
  scored.sort((a, b) => b.$2.compareTo(a.$2));
  return scored.take(limit).map((e) => e.$1).toList();
}

/// Regular vs parallel ("P-SR", "P-SEC", or "(パラレル)" in the name).
PriceResult pickPrint(List<PriceResult> candidates,
    {required bool parallel, bool sp = false}) {
  if (sp) {
    final spPrint = candidates.where(isSpPrint);
    if (spPrint.isNotEmpty) return spPrint.first;
  }
  return candidates.firstWhere(
    (c) => !isSpPrint(c) && isParallelPrint(c) == parallel,
    orElse: () => candidates.first,
  );
}

bool isSpPrint(PriceResult r) => r.rarity.toUpperCase() == 'SP';

bool isParallelPrint(PriceResult r) =>
    r.rarity.toUpperCase().startsWith('P-') || r.name.contains('パラレル');

/// Loose equality of card names.
bool namesMatch(String a, String b) => nameScore(a, b) >= 0.85;

/// 0..1 similarity of two card names, ignoring spaces, punctuation,
/// the "(パラレル)" suffix and full-width/half-width differences.
double nameScore(String a, String b) {
  final x = _normName(a), y = _normName(b);
  if (x.isEmpty || y.isEmpty) return 0;
  if (x == y) return 1;
  if (x.contains(y) || y.contains(x)) {
    final short = x.length < y.length ? x.length : y.length;
    final long = x.length < y.length ? y.length : x.length;
    return 0.85 + 0.15 * short / long;
  }
  return _dice(x, y);
}

/// Dice coefficient on character bigrams (single chars for 1-char names).
double _dice(String a, String b) {
  List<String> grams(String s) => s.length < 2
      ? [s]
      : [for (var i = 0; i < s.length - 1; i++) s.substring(i, i + 2)];
  final ga = grams(a), gb = grams(b);
  final pool = <String, int>{};
  for (final g in gb) {
    pool[g] = (pool[g] ?? 0) + 1;
  }
  var common = 0;
  for (final g in ga) {
    final n = pool[g] ?? 0;
    if (n > 0) {
      common++;
      pool[g] = n - 1;
    }
  }
  return 2 * common / (ga.length + gb.length);
}

String _normName(String s) {
  var t = s.replaceAll(RegExp(r'[(（]パラレル[)）]'), '');
  // Full-width ASCII -> half-width.
  t = String.fromCharCodes(t.runes.map(
      (r) => (r >= 0xFF01 && r <= 0xFF5E) ? r - 0xFEE0 : r));
  return t
      .toLowerCase()
      .replaceAll(RegExp(r'[\s・･&＆\-‐ー.,!！?？()（）\[\]「」]'), '');
}

/// Lower-case, half-width, no spaces: "ＥＸ Vol.5" -> "exvol.5".
String _normLoose(String s) => String.fromCharCodes(s.runes.map(
        (r) => (r >= 0xFF01 && r <= 0xFF5E) ? r - 0xFEE0 : r))
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), '');
