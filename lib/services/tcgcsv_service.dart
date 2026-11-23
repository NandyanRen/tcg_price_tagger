import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models.dart';

/// TCGplayer market prices via tcgcsv.com, a free daily mirror of
/// TCGplayer's catalog and prices (the same numbers Collectr uses).
///
/// The whole Riftbound catalog is downloaded once and cached on disk
/// for 12 hours, so searches after the first one are instant.
class TcgCsvService {
  TcgCsvService({http.Client? client}) : _client = client ?? http.Client();

  static const _base = 'https://tcgcsv.com/tcgplayer';
  static const _cacheTtl = Duration(hours: 12);

  final http.Client _client;
  List<PriceResult>? _catalog;
  DateTime? _catalogAt;
  String? _catalogCategory;

  Future<List<PriceResult>> search(String query, String categoryName) async {
    final catalog = await _loadCatalog(categoryName);
    final tokens = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return [];
    final hits = catalog.where((r) {
      final hay = '${r.name} ${r.code} ${r.rarity} ${r.variant}'.toLowerCase();
      return tokens.every(hay.contains);
    }).toList()
      ..sort((a, b) {
        final byName = a.name.compareTo(b.name);
        return byName != 0 ? byName : a.variant.compareTo(b.variant);
      });
    return hits.take(60).toList();
  }

  /// Forces a fresh download on the next search.
  Future<void> clearCache() async {
    _catalog = null;
    final f = await _cacheFile();
    if (await f.exists()) await f.delete();
  }

  Future<List<PriceResult>> _loadCatalog(String categoryName) async {
    final fresh = _catalogAt != null &&
        DateTime.now().difference(_catalogAt!) < _cacheTtl &&
        _catalogCategory == categoryName;
    if (_catalog != null && fresh) return _catalog!;

    final file = await _cacheFile();
    if (await file.exists()) {
      try {
        final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final at = DateTime.parse(j['at'] as String);
        if (j['category'] == categoryName &&
            DateTime.now().difference(at) < _cacheTtl) {
          _catalog = (j['cards'] as List)
              .map((e) => PriceResult.fromJson(e as Map<String, dynamic>))
              .toList();
          _catalogAt = at;
          _catalogCategory = categoryName;
          return _catalog!;
        }
      } catch (_) {
        // Corrupt cache: fall through and re-download.
      }
    }

    final cards = await _download(categoryName);
    _catalog = cards;
    _catalogAt = DateTime.now();
    _catalogCategory = categoryName;
    await file.writeAsString(jsonEncode({
      'at': _catalogAt!.toIso8601String(),
      'category': categoryName,
      'cards': cards.map((c) => c.toJson()).toList(),
    }));
    return cards;
  }

  Future<List<PriceResult>> _download(String categoryName) async {
    final categories = await _getResults('$_base/categories');
    final want = categoryName.toLowerCase();
    final cat = categories.cast<Map<String, dynamic>>().firstWhere(
          (c) =>
              '${c['name']} ${c['displayName']}'.toLowerCase().contains(want),
          orElse: () => throw Exception(
              'No TCGplayer category matching "$categoryName" on tcgcsv.com.'),
        );
    final catId = cat['categoryId'];

    final groups = await _getResults('$_base/$catId/groups');
    final perGroup = await Future.wait(groups.cast<Map<String, dynamic>>().map(
          (g) => _groupCards(catId, g),
        ));
    return perGroup.expand((x) => x).toList();
  }

  Future<List<PriceResult>> _groupCards(
      Object catId, Map<String, dynamic> group) async {
    final gid = group['groupId'];
    final abbr = (group['abbreviation'] as String?)?.trim() ?? '';
    final results = await Future.wait([
      _getResults('$_base/$catId/$gid/products'),
      _getResults('$_base/$catId/$gid/prices'),
    ]);
    final products = {
      for (final p in results[0].cast<Map<String, dynamic>>())
        p['productId']: p,
    };
    final out = <PriceResult>[];
    for (final price in results[1].cast<Map<String, dynamic>>()) {
      final p = products[price['productId']];
      if (p == null) continue;
      final value = (price['marketPrice'] ?? price['midPrice']) as num?;
      if (value == null) continue;
      final ext = {
        for (final e in (p['extendedData'] as List? ?? const []))
          (e as Map<String, dynamic>)['name']: e['value'],
      };
      final number = (ext['Number'] as String?)?.trim() ?? '';
      out.add(PriceResult(
        game: Game.riftbound,
        code: [abbr, number].where((s) => s.isNotEmpty).join(' '),
        name: (p['name'] as String?)?.trim() ?? '',
        rarity: (ext['Rarity'] as String?)?.trim() ?? '',
        variant: (price['subTypeName'] as String?)?.trim() ?? '',
        sourcePrice: value.toDouble(),
        currency: 'USD',
        sourceUrl: (p['url'] as String?) ?? '',
      ));
    }
    return out;
  }

  Future<List<dynamic>> _getResults(String url) async {
    final res = await _client.get(Uri.parse(url));
    if (res.statusCode != 200) {
      throw Exception('tcgcsv.com returned HTTP ${res.statusCode} for $url');
    }
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return j['results'] as List? ?? const [];
  }

  Future<File> _cacheFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}tcgcsv_cache.json');
  }
}
