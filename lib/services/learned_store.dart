import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models.dart';
import 'auto_pricer.dart' show nameScore;
import 'yuyutei_service.dart';

/// A card you confirmed or corrected: the listing it really is, what the
/// recognizer read for it, and crops of it from your photos.
class LearnedCard {
  PriceResult listing;
  final Set<String> readNames;
  final Set<String> readCodes;
  final List<String> cropFiles;
  DateTime updatedAt;

  LearnedCard({
    required this.listing,
    Set<String>? readNames,
    Set<String>? readCodes,
    List<String>? cropFiles,
    DateTime? updatedAt,
  })  : readNames = readNames ?? {},
        readCodes = readCodes ?? {},
        cropFiles = cropFiles ?? [],
        updatedAt = updatedAt ?? DateTime.now();

  /// Identifies one listing (one print) independent of its current price.
  static String keyOf(PriceResult r) =>
      '${r.game.name}|${r.code}|${r.rarity}|${r.name}';

  String get key => keyOf(listing);

  Map<String, dynamic> toJson() => {
        'listing': listing.toJson(),
        'readNames': readNames.toList(),
        'readCodes': readCodes.toList(),
        'cropFiles': cropFiles,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory LearnedCard.fromJson(Map<String, dynamic> j) => LearnedCard(
        listing: PriceResult.fromJson(j['listing'] as Map<String, dynamic>),
        readNames: {...(j['readNames'] as List? ?? const []).cast<String>()},
        readCodes: {...(j['readCodes'] as List? ?? const []).cast<String>()},
        cropFiles: [...(j['cropFiles'] as List? ?? const []).cast<String>()],
        updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
      );
}

/// Remembers your corrections so the next auto-detect knows about them.
/// Stored in the app's support folder (learned.json + learned/ crops).
class LearnedStore {
  final Map<String, LearnedCard> _cards = {};
  Directory? _dir;
  bool _loaded = false;

  static const _maxCropsPerCard = 3;

  int get count => _cards.length;

  Future<Directory> _folder() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}learned');
    await d.create(recursive: true);
    return _dir = d;
  }

  File _indexFile(Directory d) =>
      File('${d.path}${Platform.pathSeparator}learned.json');

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = _indexFile(await _folder());
      if (!await f.exists()) return;
      final list = jsonDecode(await f.readAsString()) as List;
      for (final e in list) {
        final c = LearnedCard.fromJson(e as Map<String, dynamic>);
        _cards[c.key] = c;
      }
    } catch (_) {
      // Unreadable file: start fresh rather than crash.
    }
  }

  Future<void> _save() async {
    final d = await _folder();
    await _indexFile(d).writeAsString(
        jsonEncode(_cards.values.map((c) => c.toJson()).toList()));
  }

  /// Records that a pile read as [readName]/[readCode] is [listing].
  Future<void> remember(
    PriceResult listing, {
    required String readName,
    required String readCode,
    Uint8List? crop,
  }) async {
    await load();
    final key = LearnedCard.keyOf(listing);
    final card = _cards.putIfAbsent(key, () => LearnedCard(listing: listing));
    card.listing = listing; // keep the newest price / picture link
    if (readName.trim().isNotEmpty) card.readNames.add(readName.trim());
    final code = YuyuteiService.normalizeCode(readCode);
    if (code.isNotEmpty) card.readCodes.add(code);
    // The listing's own name and code always count as a match too.
    card.readNames.add(listing.name);
    card.readCodes.add(listing.code);
    card.updatedAt = DateTime.now();

    if (crop != null) {
      final d = await _folder();
      final file = 'crop_${DateTime.now().microsecondsSinceEpoch}.jpg';
      await File('${d.path}${Platform.pathSeparator}$file').writeAsBytes(crop);
      card.cropFiles.add(file);
      while (card.cropFiles.length > _maxCropsPerCard) {
        final old = card.cropFiles.removeAt(0);
        try {
          await File('${d.path}${Platform.pathSeparator}$old').delete();
        } catch (_) {}
      }
    }
    await _save();
  }

  /// Listings you taught earlier that fit what was read for a pile.
  Future<List<PriceResult>> matches(
      Game game, String readName, String readCode) async {
    await load();
    final code = YuyuteiService.normalizeCode(readCode);
    final out = <PriceResult>[];
    for (final c in _cards.values) {
      if (c.listing.game != game) continue;
      final nameHit = readName.isNotEmpty &&
          c.readNames.any((n) => nameScore(n, readName) >= 0.85);
      final codeHit = code.isNotEmpty && c.readCodes.contains(code);
      // Codes are often misread, so the name is enough; the picture
      // check still has the final say.
      if (nameHit || (codeHit && readName.isEmpty)) out.add(c.listing);
    }
    return out;
  }

  /// Your earlier photo of this listing (newest first), if any.
  Future<Uint8List?> pictureFor(PriceResult listing) async {
    await load();
    final c = _cards[LearnedCard.keyOf(listing)];
    if (c == null || c.cropFiles.isEmpty) return null;
    final d = await _folder();
    for (final f in c.cropFiles.reversed) {
      final file = File('${d.path}${Platform.pathSeparator}$f');
      if (await file.exists()) return file.readAsBytes();
    }
    return null;
  }

  bool isLearned(PriceResult listing) =>
      _cards.containsKey(LearnedCard.keyOf(listing));

  Future<void> clear() async {
    await load();
    _cards.clear();
    try {
      final d = await _folder();
      await d.delete(recursive: true);
      _dir = null;
    } catch (_) {}
  }
}
