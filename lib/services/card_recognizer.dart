import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import '../debug_log.dart';
import '../models.dart';

/// One pile of identical cards found in the photo.
class DetectedPile {
  final String code; // as printed, e.g. "BT23-075" (may be empty or partial)
  final String name; // as printed, Japanese if the card is Japanese
  final bool parallel;

  /// SP: special reprint, marked by an "SP" box before the card number
  /// (the design differs per set).
  final bool sp;
  final int qty;

  /// Center of the top card, normalized to the photo (0..1).
  final double x, y;

  /// Size of the top card, normalized (0 when unknown).
  final double w, h;

  const DetectedPile({
    required this.code,
    required this.name,
    required this.parallel,
    this.sp = false,
    required this.qty,
    required this.x,
    required this.y,
    this.w = 0,
    this.h = 0,
  });
}

class RecognitionResult {
  final Game? game;
  final List<DetectedPile> piles;
  const RecognitionResult(this.game, this.piles);
}

/// Photo prepared for the API: downscaled JPEG and the size Claude sees.
class PreparedPhoto {
  final Uint8List jpeg;
  final int width, height;

  /// The original photo, for full-resolution crops of single cards.
  final Uint8List original;
  const PreparedPhoto(this.jpeg, this.width, this.height, this.original);
}

/// Uses Claude's vision API to find card piles in a photo, and (second pass)
/// to match unresolved piles against a real card list from the price site.
class CardRecognizer {
  CardRecognizer({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _schema = {
    'type': 'object',
    'properties': {
      'game': {
        'type': 'string',
        'enum': ['digimon', 'one_piece', 'riftbound', 'unknown'],
      },
      'piles': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'code': {'type': 'string'},
            'name': {'type': 'string'},
            'parallel': {'type': 'boolean'},
            'sp': {'type': 'boolean'},
            'qty': {'type': 'integer'},
            'x': {'type': 'number'},
            'y': {'type': 'number'},
            'w': {'type': 'number'},
            'h': {'type': 'number'},
          },
          'required': ['code', 'name', 'parallel', 'qty', 'x', 'y'],
        },
      },
    },
    'required': ['game', 'piles'],
  };

  static String _detectPrompt(int w, int h) => '''
This is a ${w}x$h photo of trading cards laid out for sale. Copies of the same card are usually fanned out in a pile, with only the edges of the cards underneath showing.

Report one entry per pile (a single loose card counts as a pile of 1). Include every card in the photo: characters, Tamers/leaders, events/Options, and cards fanned out at the edges or set apart in a small stack.

- code: the full card number printed on the card (e.g. BT23-075, EX10-012, EB05-061), usually in small print near the bottom right. Read all three digits carefully. If it is unreadable, give your best identification; if you really can't tell, use "".
- name: the card name exactly as printed (Japanese if the card is Japanese).
- parallel: true for parallel / alternate-art versions (including SP).
- sp: true for SP cards. The one sure sign is a small box reading "SP" printed just before the card number at the bottom (e.g. "SP OP14-033 SR", "SP OP13-113 R", "SP ST32-002 SR"). The SP design is different in every set (e.g. huge foil name lettering in one set, a bright star-patterned full art in another, black-and-white manga sketch art with red accents in another), so judge mainly by that box; a fancy full-art design alone is not enough. SP cards keep the card number AND rarity letters of their original, older set, so a printed "SR" or "R" does not mean it is a regular print.
- qty: count the copies in the pile by the visible card edges or corner cost circles.
- x, y: pixel coordinates of the center of the top (fully visible) card, in this ${w}x$h image.
- w, h: pixel width and height of that top card.

Reply with ONLY a JSON object (no markdown, no explanation) matching this JSON schema:
${jsonEncode(_schema)}
''';

  /// Downscale once and reuse the result for both passes.
  Future<PreparedPhoto> prepare(Uint8List photoBytes, {int maxEdge = 1568}) =>
      _downscaleToJpeg(photoBytes, maxEdge);

  Future<RecognitionResult> recognize(
    PreparedPhoto photo, {
    required String apiKey,
    required String model,
  }) async {
    final w = photo.width, h = photo.height;
    final input = await _ask(photo, _detectPrompt(w, h),
        apiKey: apiKey, model: model, requiredKey: 'piles');

    final game = switch (input['game']) {
      'digimon' => Game.digimon,
      'one_piece' => Game.onePiece,
      'riftbound' => Game.riftbound,
      _ => null,
    };
    final piles = <DetectedPile>[];
    for (final p in (input['piles'] as List? ?? const [])) {
      if (p is! Map) continue;
      final m = p.cast<String, dynamic>();
      final x = (m['x'] as num?)?.toDouble();
      final y = (m['y'] as num?)?.toDouble();
      if (x == null || y == null) continue;
      piles.add(DetectedPile(
        code: (m['code'] as String? ?? '').trim(),
        name: (m['name'] as String? ?? '').trim(),
        parallel: (m['parallel'] as bool? ?? false) || (m['sp'] as bool? ?? false),
        sp: m['sp'] as bool? ?? false,
        qty: ((m['qty'] as num?)?.toInt() ?? 1).clamp(1, 99),
        x: (x / w).clamp(0.0, 1.0),
        y: (y / h).clamp(0.0, 1.0),
        w: (((m['w'] as num?)?.toDouble() ?? 0) / w).clamp(0.0, 1.0),
        h: (((m['h'] as num?)?.toDouble() ?? 0) / h).clamp(0.0, 1.0),
      ));
    }
    return RecognitionResult(game, piles);
  }

  /// Second pass: for each pile (by index), ask Claude to pick the matching
  /// entry from [catalog]. Returns pile index -> chosen catalog entry.
  Future<Map<int, PriceResult>> matchToCatalog(
    PreparedPhoto photo,
    Map<int, DetectedPile> piles,
    List<PriceResult> catalog, {
    required String apiKey,
    required String model,
  }) async {
    if (piles.isEmpty || catalog.isEmpty) return {};
    final w = photo.width, h = photo.height;

    final catalogLines = <String>[];
    for (var i = 0; i < catalog.length; i++) {
      final c = catalog[i];
      catalogLines.add('$i | ${c.code} | ${c.rarity} | ${c.name}');
    }
    final pileLines = piles.entries.map((e) {
      final p = e.value;
      return '${e.key} | x=${(p.x * w).round()}, y=${(p.y * h).round()} | '
          'read as "${p.name}" ${p.code.isEmpty ? '' : '(${p.code})'}'
          '${p.sp ? ' | looks SP' : p.parallel ? ' | looks parallel' : ''}';
    }).join('\n');

    final prompt = '''
This is a ${w}x$h photo of trading cards for sale. I couldn't match some piles to a price list. For each pile below (id | center pixel of its top card | what was read earlier), look at that card in the photo and pick the matching entry from the catalog.

Piles:
$pileLines

The printed codes may have been misread, so trust the name and artwork over the code.

Catalog (index | code | rarity | name). Rarities starting with "P-" are parallel / alternate-art prints. "SP" are special reprints marked by a small "SP" box before the card number; their design varies by set, and they keep the card number and rarity letters of their original set. Pick the print that matches the card in the photo:
${catalogLines.join('\n')}

Reply with ONLY a JSON object (no markdown, no explanation) like:
{"matches": [{"id": 0, "catalog_index": 12}]}
Use "catalog_index": -1 if the card is not in the catalog.
''';

    final input = await _ask(photo, prompt,
        apiKey: apiKey, model: model, requiredKey: 'matches');
    final out = <int, PriceResult>{};
    for (final m in (input['matches'] as List? ?? const [])) {
      if (m is! Map) continue;
      final id = (m['id'] as num?)?.toInt();
      final idx = (m['catalog_index'] as num?)?.toInt();
      if (id == null || idx == null || idx < 0 || idx >= catalog.length) {
        continue;
      }
      if (piles.containsKey(id)) out[id] = catalog[idx];
    }
    return out;
  }

  /// Picture check: for each pile, show Claude a full-resolution crop next
  /// to the store's picture of every candidate print and let it pick by the
  /// artwork, or answer that none match.
  ///
  /// Returns the chosen print per pile, and which piles were actually
  /// compared (a compared pile missing from [chosen] means "none match").
  Future<({Map<int, PriceResult> chosen, Set<int> compared})> choosePrints(
    PreparedPhoto photo,
    Map<int, ({DetectedPile pile, List<PriceResult> prints})> items, {
    required String apiKey,
    required String model,
    String sellerHint = '',
    Future<Uint8List?> Function(PriceResult)? learnedPicture,
  }) async {
    final chosen = <int, PriceResult>{};
    final compared = <int>{};
    if (items.isEmpty) return (chosen: chosen, compared: compared);

    // Crop from the original photo so small print (the "SP" box next to
    // the card number) is readable; fall back to the downscaled copy.
    final decoded = img.decodeImage(photo.original);
    final full = decoded != null
        ? img.bakeOrientation(decoded) // match how Flutter shows the photo
        : img.decodeJpg(photo.jpeg);
    if (full == null) return (chosen: chosen, compared: compared);

    // Build one block of content per pile.
    final blocks = <int, List<Map<String, dynamic>>>{};
    final optionMap = <int, Map<String, PriceResult>>{};
    final imageCount = <int, int>{};
    final fromYourPhotos = <String>{};
    for (final e in items.entries) {
      final options = <String, PriceResult>{};
      final refs = <(String, Uint8List?)>[]; // null = no store picture
      var letter = 'A'.codeUnitAt(0);
      for (final print in e.value.prints) {
        Uint8List? small;
        if (print.imageUrl.isNotEmpty) {
          final bytes = await _download(print.imageUrl);
          small = bytes == null ? null : _shrink(bytes);
          if (small != null && _isPlaceholder(print.imageUrl, bytes!)) {
            small = null; // "NowPrinting" etc.
          }
          DebugLog.text(
              'pile${e.key}_${print.code}_${print.rarity}_download.txt',
              '${print.imageUrl}\n'
              '${bytes == null ? 'FAILED' : '${bytes.length} bytes'}'
              '${bytes != null && small == null ? ' (placeholder)' : ''}');
          if (small != null) {
            DebugLog.bytes(
                'pile${e.key}_${print.code}_${print.rarity}_ref.jpg', small);
          }
        }
        // No usable store picture: use your earlier photo of it, if any.
        var fromYou = false;
        if (small == null && learnedPicture != null) {
          final mine = await learnedPicture(print);
          if (mine != null) {
            small = _shrink(mine);
            fromYou = small != null;
          }
        }
        final id = String.fromCharCode(letter++);
        options[id] = print;
        refs.add((id, small));
        if (fromYou) fromYourPhotos.add('${e.key}$id');
      }
      // Nothing to look at: leave this pile to the best text match.
      if (refs.every((r) => r.$2 == null)) {
        DebugLog.text('pile${e.key}_skipped.txt', 'No store pictures');
        continue;
      }
      final crop = _crop(full, e.value.pile);
      DebugLog.bytes('pile${e.key}_crop.jpg', crop);
      final block = <Map<String, dynamic>>[
        {'type': 'text', 'text': 'Pile ${e.key} (photo crop):'},
        _imageBlock(crop, 'image/jpeg'),
      ];
      var pictures = 1;
      for (final (id, bytes) in refs) {
        final p = options[id]!;
        final label = 'Pile ${e.key}, option $id: ${p.code} ${p.rarity} ${p.name}';
        if (bytes == null) {
          block.add({
            'type': 'text',
            'text': '$label (NO STORE PICTURE AVAILABLE)',
          });
        } else {
          block.add({
            'type': 'text',
            'text': fromYourPhotos.contains('${e.key}$id')
                ? '$label (picture from the seller\'s earlier photo of this '
                    'exact card, confirmed by them)'
                : label,
          });
          block.add(_imageBlock(bytes, 'image/jpeg'));
          pictures++;
        }
      }
      blocks[e.key] = block;
      optionMap[e.key] = options;
      imageCount[e.key] = pictures;
    }

    // The API takes up to 100 images per request: send in chunks.
    final ids = blocks.keys.toList();
    var i = 0;
    while (i < ids.length) {
      final chunk = <int>[];
      var images = 0;
      while (i < ids.length &&
          (chunk.isEmpty || images + imageCount[ids[i]]! <= 80)) {
        images += imageCount[ids[i]]!;
        chunk.add(ids[i++]);
      }
      final content = <Map<String, dynamic>>[
        {'type': 'text', 'text': _choosePrompt},
        if (sellerHint.trim().isNotEmpty)
          {
            'type': 'text',
            'text': 'Seller note: these cards are from "${sellerHint.trim()}". '
                'Options whose name mentions it are very likely the right '
                'ones, even without a store picture.',
          },
        for (final id in chunk) ...blocks[id]!,
        {
          'type': 'text',
          'text': 'Reply with ONLY a JSON object (no markdown, no explanation) '
              'like {"choices": [{"id": 0, "option": "A"}, {"id": 1, "option": null}]} '
              'with one entry for each pile above.',
        },
      ];
      final input = await _send(content,
          apiKey: apiKey, model: model, requiredKey: 'choices');
      compared.addAll(chunk);
      for (final c in (input['choices'] as List? ?? const [])) {
        if (c is! Map) continue;
        final id = (c['id'] as num?)?.toInt();
        final opt = (c['option'] as String?)?.trim().toUpperCase();
        final pick = optionMap[id]?[opt];
        if (id != null && pick != null) chosen[id] = pick;
      }
    }
    return (chosen: chosen, compared: compared);
  }

  static const _choosePrompt =
      'Each numbered pile below is a crop from a photo of trading cards for '
      'sale (often inside sleeves or toploaders), followed by store pictures '
      'of candidate cards (lettered options). Candidates can be different '
      'cards with the same name, or different prints of one card: regular, '
      'parallel / alternate art, or SP. SP prints carry a small "SP" box just '
      'before the card number (e.g. "SP OP13-113 R"; the original rarity is '
      'still printed), and their design differs from set to set. The crops '
      'are full resolution. For each pile, pick the option whose artwork is '
      'the same card as in the crop. Different art means a different print. '
      'Some options have NO STORE PICTURE (usually new promo or special '
      'versions, e.g. "(パラレル)(プロモーションパック…)"): pick such an option '
      'only when the crop clearly does not match any pictured option with the '
      'same card number, and its name fits (e.g. the crop is an alternate-art '
      'version and the no-picture option is the parallel/promo). '
      'If nothing fits, answer null.';

  /// Crop of one card from the original photo, e.g. to remember it.
  static Future<Uint8List?> cropFromPhoto(Uint8List original,
      {required double x, required double y, double w = 0, double h = 0}) {
    return Isolate.run(() {
      final decoded = img.decodeImage(original);
      if (decoded == null) return null;
      final full = img.bakeOrientation(decoded);
      var crop = _crop(
          full,
          DetectedPile(
              code: '', name: '', parallel: false, qty: 1, x: x, y: y, w: w, h: h));
      final im = img.decodeJpg(crop);
      if (im != null && im.height > 700) {
        crop = img.encodeJpg(img.copyResize(im, height: 700), quality: 88);
      }
      return crop;
    });
  }

  /// Crop around the pile's top card (with a little margin).
  static Uint8List _crop(img.Image full, DetectedPile p) {
    final fw = full.width.toDouble(), fh = full.height.toDouble();
    final cardW = p.w > 0 ? p.w * fw : 0.16 * fw;
    final cardH = p.h > 0 ? p.h * fh : cardW * 1.4;
    final cw = (cardW * 1.15).clamp(32.0, fw).toDouble();
    final ch = (cardH * 1.15).clamp(32.0, fh).toDouble();
    final left = (p.x * fw - cw / 2).clamp(0.0, fw - cw);
    final top = (p.y * fh - ch / 2).clamp(0.0, fh - ch);
    var crop = img.copyCrop(full,
        x: left.round(), y: top.round(), width: cw.round(), height: ch.round());
    if (crop.height > 1000) crop = img.copyResize(crop, height: 1000);
    return img.encodeJpg(crop, quality: 90);
  }

  /// Downloads a store picture. Tries a larger size first on Yuyu-tei
  /// (thumbnails are 100x140), and only accepts JPEG/PNG/WebP/GIF data.
  Future<Uint8List?> _download(String url) async {
    final bigger = url.replaceFirst('/100_140/', '/front/');
    if (bigger != url) {
      final b = await _get(bigger);
      if (b != null) return b;
    }
    return _get(url);
  }

  Future<Uint8List?> _get(String url) async {
    try {
      final res = await _client.get(Uri.parse(url), headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/130.0 Safari/537.36',
        'Referer': 'https://yuyu-tei.jp/',
      });
      if (res.statusCode != 200 || res.bodyBytes.length < 100) return null;
      return _isRaster(res.bodyBytes) ? res.bodyBytes : null;
    } catch (_) {
      return null;
    }
  }

  /// Fingerprints of downloaded store pictures, to spot one placeholder
  /// image ("NowPrinting") shared by several different cards.
  final Map<String, Set<String>> _seenImages = {};

  /// True for "no image yet" pictures: a placeholder-looking URL, the same
  /// image used for different cards, or a grey picture with almost no color
  /// (real card art is colorful).
  bool _isPlaceholder(String url, Uint8List bytes) {
    final u = url.toLowerCase();
    if (RegExp(r'no_?image|now_?printing|dummy|coming_?soon|noimg')
        .hasMatch(u)) {
      return true;
    }
    final fp = '${bytes.length}:${bytes.take(64).join(',')}:'
        '${bytes.skip(bytes.length > 64 ? bytes.length - 64 : 0).join(',')}';
    final urls = _seenImages.putIfAbsent(fp, () => <String>{})..add(url);
    if (urls.length > 1) return true;

    final im = img.decodeImage(bytes);
    if (im == null) return false;
    // Grey AND flat: manga-style black-and-white art has little color too,
    // but strong contrast, so it isn't mistaken for a placeholder.
    final t = img.copyResize(im, width: 24);
    var satSum = 0.0, lumSum = 0.0, lumSq = 0.0, n = 0;
    for (final px in t) {
      final r = px.r / 255, g = px.g / 255, b = px.b / 255;
      final mx = [r, g, b].reduce((a, c) => a > c ? a : c);
      final mn = [r, g, b].reduce((a, c) => a < c ? a : c);
      satSum += mx == 0 ? 0 : (mx - mn) / mx;
      final lum = 0.299 * r + 0.587 * g + 0.114 * b;
      lumSum += lum;
      lumSq += lum * lum;
      n++;
    }
    if (n == 0) return false;
    final mean = lumSum / n;
    final std = (lumSq / n - mean * mean).clamp(0.0, 1.0);
    // std is the variance of 0..1 luminance.
    final greyFlat = satSum / n < 0.12 && std < 0.025;
    // "Now Printing": pale cream background with one big orange word.
    final paleFlat = mean > 0.7 && std < 0.03;
    return greyFlat || paleFlat;
  }

  /// Store pictures can be ~500 KB; 400 px wide is plenty to compare art.
  static Uint8List? _shrink(Uint8List bytes) {
    final im = img.decodeImage(bytes);
    if (im == null) return null;
    final out = im.width > 400 ? img.copyResize(im, width: 400) : im;
    return img.encodeJpg(out, quality: 85);
  }

  static bool _isRaster(Uint8List b) =>
      b.length > 12 &&
      ((b[0] == 0xFF && b[1] == 0xD8) || // JPEG
          (b[0] == 0x89 && b[1] == 0x50) || // PNG
          (b[0] == 0x47 && b[1] == 0x49) || // GIF
          (b[8] == 0x57 && b[9] == 0x45)); // WebP

  static String _mediaType(Uint8List b) {
    if (b.length > 3 && b[0] == 0x89 && b[1] == 0x50) return 'image/png';
    if (b.length > 3 && b[0] == 0x47 && b[1] == 0x49) return 'image/gif';
    if (b.length > 11 && b[8] == 0x57 && b[9] == 0x45) return 'image/webp';
    return 'image/jpeg';
  }

  static Map<String, dynamic> _imageBlock(Uint8List bytes, String mediaType) => {
        'type': 'image',
        'source': {
          'type': 'base64',
          'media_type': mediaType,
          'data': base64Encode(bytes),
        },
      };

  Future<Map<String, dynamic>> _ask(
    PreparedPhoto photo,
    String prompt, {
    required String apiKey,
    required String model,
    required String requiredKey,
  }) =>
      _send([
        _imageBlock(photo.jpeg, 'image/jpeg'),
        {'type': 'text', 'text': prompt},
      ], apiKey: apiKey, model: model, requiredKey: requiredKey);

  Future<Map<String, dynamic>> _send(
    List<Map<String, dynamic>> content, {
    required String apiKey,
    required String model,
    required String requiredKey,
  }) async {
    final res = await _client.post(
      Uri.parse('https://api.anthropic.com/v1/messages'),
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'model': model,
        'max_tokens': 8000,
        'messages': [
          {'role': 'user', 'content': content},
        ],
      }),
    );
    DebugLog.text(
        'claude_${requiredKey}_request.txt',
        content
            .map((c) => c['type'] == 'text' ? c['text'] : '[image]')
            .join('\n'));
    DebugLog.text('claude_${requiredKey}_response.json', utf8.decode(res.bodyBytes));

    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      final msg = (body['error'] as Map?)?['message'] ?? res.body;
      throw Exception('Claude API error ${res.statusCode}: $msg');
    }
    return _extractJson(body['content'] as List, requiredKey);
  }

  /// Finds the JSON object in the reply (tool input or text).
  static Map<String, dynamic> _extractJson(List content, String requiredKey) {
    final blocks = content.whereType<Map>().map((b) => b.cast<String, dynamic>());
    for (final b in blocks) {
      if (b['type'] == 'tool_use' && b['input'] is Map) {
        return (b['input'] as Map).cast<String, dynamic>();
      }
    }
    for (final b in blocks) {
      if (b['type'] != 'text') continue;
      final text = b['text'] as String? ?? '';
      final start = text.indexOf('{');
      final end = text.lastIndexOf('}');
      if (start < 0 || end <= start) continue;
      try {
        final j = jsonDecode(text.substring(start, end + 1));
        if (j is Map && j[requiredKey] is List) return j.cast<String, dynamic>();
      } catch (_) {}
    }
    throw Exception(
        'Claude did not return any cards. Try again, or try another model in settings.');
  }

  /// Resizes so the long edge is at most [maxEdge] and encodes as JPEG.
  static Future<PreparedPhoto> _downscaleToJpeg(
      Uint8List bytes, int maxEdge) async {
    final probe = await ui.instantiateImageCodec(bytes);
    final full = (await probe.getNextFrame()).image;
    final scale = maxEdge / (full.width > full.height ? full.width : full.height);
    final w = scale < 1 ? (full.width * scale).round() : full.width;
    final h = scale < 1 ? (full.height * scale).round() : full.height;
    full.dispose();

    final codec = await ui.instantiateImageCodec(bytes,
        targetWidth: w, targetHeight: h);
    final frame = (await codec.getNextFrame()).image;
    final rgba = await frame.toByteData(format: ui.ImageByteFormat.rawRgba);
    frame.dispose();

    final image = img.Image.fromBytes(
      width: w,
      height: h,
      bytes: rgba!.buffer,
      numChannels: 4,
    );
    return PreparedPhoto(img.encodeJpg(image, quality: 90), w, h, bytes);
  }
}
