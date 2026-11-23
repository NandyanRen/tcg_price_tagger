import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../debug_log.dart';
import '../exporter.dart';
import '../models.dart';
import '../pricing.dart';
import '../services/auto_pricer.dart';
import '../services/card_recognizer.dart';
import '../services/learned_store.dart';
import '../services/tcgcsv_service.dart';
import '../services/yuyutei_service.dart';
import '../settings.dart';
import 'price_dialog.dart';
import 'settings_panel.dart';
import 'tag_painter.dart';

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

class EditorPage extends StatefulWidget {
  const EditorPage({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  final _yuyutei = YuyuteiService();
  final _tcgcsv = TcgCsvService();
  final _recognizer = CardRecognizer();
  final _learned = LearnedStore();
  int _learnedCount = 0;

  @override
  void initState() {
    super.initState();
    _learned.load().then((_) {
      if (mounted) setState(() => _learnedCount = _learned.count);
    });
  }
  late final _autoPricer = AutoPricer(_yuyutei, _tcgcsv);

  bool _detecting = false;
  String _detectStatus = '';
  late final _setHint = TextEditingController(text: widget.settings.setHint);

  Uint8List? _imageBytes;
  ui.Image? _image;
  String? _imageName;
  final List<PriceTag> _tags = [];
  String? _selectedId;
  int _nextId = 0;

  AppSettings get _s => widget.settings;

  @override
  void dispose() {
    _setHint.dispose();
    super.dispose();
  }

  static const _imageTypes = XTypeGroup(
    label: 'Images',
    extensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp'],
  );

  // ---------- file actions ----------

  Future<void> _openPhoto() async {
    final file = await openFile(acceptedTypeGroups: [_imageTypes]);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    setState(() {
      _image?.dispose();
      _imageBytes = bytes;
      _image = frame.image;
      _imageName = file.name;
      _tags.clear();
      _selectedId = null;
    });
  }

  Future<void> _export() async {
    final image = _image;
    if (image == null) return;
    final base = (_imageName ?? 'cards').replaceFirst(RegExp(r'\.[^.]+$'), '');
    final loc = await getSaveLocation(
      suggestedName: '${base}_priced.png',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PNG', extensions: ['png'])
      ],
    );
    if (loc == null) return;
    var path = loc.path;
    if (!path.toLowerCase().endsWith('.png')) path = '$path.png';
    final bytes = await renderExport(image, _tags, _s);
    await File(path).writeAsBytes(bytes);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Saved $path')),
    );
  }

  Future<void> _copySummary() async {
    final lines = [
      for (final t in _tags)
        '${t.cardName.isEmpty ? t.code : t.cardName}'
            '${t.rarity.isEmpty ? '' : ' (${t.rarity})'}'
            '${t.qty > 1 ? ' ×${t.qty}' : ''}'
            ' — ${t.pricePhp == null ? '${_s.currencySymbol}?' : '${_s.currencySymbol}${formatThousands(t.pricePhp! * t.qty)}'}',
      'Total: ${_s.currencySymbol}${formatThousands(totalPhp(_tags))}',
    ];
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Price list copied to clipboard')),
    );
  }

  // ---------- tag actions ----------

  Future<void> _addTagAt(Offset normalized) async {
    final r = await PriceDialog.show(context,
        settings: _s, yuyutei: _yuyutei, tcgcsv: _tcgcsv);
    if (r == null) return;
    setState(() {
      final tag = PriceTag(
        id: '${_nextId++}',
        pos: normalized,
        pricePhp: r.pricePhp,
        qty: r.qty,
        cardName: r.cardName,
        code: r.code,
        rarity: r.rarity,
        source: r.source,
      );
      _tags.add(tag);
      _selectedId = tag.id;
    });
  }

  Future<void> _editTag(PriceTag t) async {
    setState(() => _selectedId = t.id);
    final r = await PriceDialog.show(context,
        settings: _s, yuyutei: _yuyutei, tcgcsv: _tcgcsv, initial: t);
    if (r == null) return;
    setState(() {
      t
        ..pricePhp = r.pricePhp
        ..qty = r.qty
        ..cardName = r.cardName
        ..code = r.code
        ..rarity = r.rarity
        ..source = r.source
        ..needsReview = false;
    });
    await _learnFrom(t);
  }

  /// Remembers a corrected or confirmed auto-detected tag for next time:
  /// what was read, which listing it really is, and a crop of the card.
  Future<void> _learnFrom(PriceTag t) async {
    final src = t.source;
    final bytes = _imageBytes;
    if (src == null || !t.wasAutoDetected || bytes == null) return;
    try {
      final crop = await CardRecognizer.cropFromPhoto(bytes,
          x: t.pos.dx, y: t.pos.dy, w: t.readW, h: t.readH);
      await _learned.remember(src,
          readName: t.readName, readCode: t.readCode, crop: crop);
      if (!mounted) return;
      setState(() => _learnedCount = _learned.count);
      _snack('Learned: ${src.name} (${src.code} ${src.rarity}). '
          'Auto-detect will know this card next time.');
    } catch (_) {
      // Learning is a bonus; never block editing.
    }
  }

  void _clearTags() => setState(() {
        _tags.clear();
        _selectedId = null;
      });

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Reads the photo with Claude, then looks up a price for every pile.
  Future<void> _autoDetect() async {
    final bytes = _imageBytes;
    if (bytes == null || _detecting) return;
    if (_s.anthropicApiKey.isEmpty) {
      _snack('Add your Claude API key under "Pricing & tag settings" first.');
      return;
    }
    setState(() {
      _detecting = true;
      _detectStatus = 'Reading the cards in the photo…';
    });
    try {
      await DebugLog.start();
      final photo = await _recognizer.prepare(bytes);
      final result = await _recognizer.recognize(
        photo,
        apiKey: _s.anthropicApiKey,
        model: _s.visionModel,
      );
      final game = result.game ?? _s.lastGame;
      _s.lastGame = game;
      await _s.save();
      final piles = result.piles;
      if (!mounted) return;
      setState(() => _detectStatus =
          'Found ${piles.length} piles. Looking up prices on ${game.sourceName}…');

      final prices = <int, PriceResult>{};
      final hintSets = game.yuyuteiSlug == null
          ? const <String>[]
          : AutoPricer.parseSetHint(_setHint.text);
      final hintKeywords = AutoPricer.parseHintKeywords(_setHint.text);

      if (game.yuyuteiSlug == null) {
        // Riftbound / TCGplayer: one lookup per pile.
        for (var i = 0; i < piles.length; i++) {
          final known =
              await _learned.matches(game, piles[i].name, piles[i].code);
          if (known.isNotEmpty) {
            prices[i] = known.first;
            continue;
          }
          try {
            final r = await _autoPricer.priceFor(piles[i], game,
                riftboundCategory: _s.riftboundCategory);
            if (r != null) prices[i] = r;
          } catch (_) {}
        }
      } else {
        // 1. Load the card lists: your set hint first (SP reprints are
        //    listed there under their old numbers), then the sets from the
        //    codes Claude read.
        final pageSets =
            <String>{...hintSets, ...AutoPricer.setsInPhoto(piles)}.toList();
        if (!mounted) return;
        setState(() => _detectStatus =
            'Found ${piles.length} piles. Loading ${pageSets.join(', ')} from ${game.sourceName}…');
        final allCards = await _autoPricer.catalogFor(game, pageSets);

        // Also search Yuyu-tei by each card number read: finds promo-pack
        // and SP prints of that number from any set.
        final searched = <int, List<PriceResult>>{};
        await Future.wait([
          for (var i = 0; i < piles.length; i++)
            _yuyutei.searchCode(game, piles[i].code).then((r) {
              if (r.isNotEmpty) searched[i] = r;
            }),
        ]);

        // 2. Candidates per pile, found mainly by name.
        final cands = <int, List<PriceResult>>{};
        for (var i = 0; i < piles.length; i++) {
          final pool = [...allCards, ...?searched[i]];
          final c = candidatesFor(piles[i], pool,
              hintSets: hintSets, hintKeywords: hintKeywords);

          // Cards you corrected or confirmed before go first, with a
          // fresh price when the listing can be found again.
          final learned = <PriceResult>[];
          for (final l in await _learned.matches(
              game, piles[i].name, piles[i].code)) {
            final key = LearnedCard.keyOf(l);
            var fresh = pool.where((x) => LearnedCard.keyOf(x) == key).firstOrNull;
            fresh ??= (await _yuyutei.searchCode(game, l.code))
                .where((x) => LearnedCard.keyOf(x) == key)
                .firstOrNull;
            learned.add(fresh ?? l);
          }
          final keys = learned.map(LearnedCard.keyOf).toSet();
          final merged = [
            ...learned,
            ...c.where((x) => !keys.contains(LearnedCard.keyOf(x))),
          ].take(7).toList();
          if (merged.isNotEmpty) cands[i] = merged;
        }

        // 3. Piles with no name match: let Claude pick from the card list.
        final noMatch = {
          for (var i = 0; i < piles.length; i++)
            if (!cands.containsKey(i)) i: piles[i],
        };
        if (noMatch.isNotEmpty && allCards.isNotEmpty) {
          if (!mounted) return;
          setState(() => _detectStatus =
              'Looking up ${noMatch.length} unclear cards in the card list…');
          final listCards = hintSets.isEmpty
              ? allCards
              : allCards
                  .where((c) => hintSets.any((h) =>
                      c.sourceUrl.toLowerCase().endsWith('/s/${h.toLowerCase()}')))
                  .toList();
          try {
            final matched = await _recognizer.matchToCatalog(
              photo,
              noMatch,
              listCards.isEmpty ? allCards : listCards,
              apiKey: _s.anthropicApiKey,
              model: _s.visionModel,
            );
            for (final e in matched.entries) {
              cands[e.key] =
                  allCards.where((c) => c.code == e.value.code).take(6).toList();
            }
          } catch (_) {}
        }

        // 4. Picture check: every candidate is compared with the photo.
        //    Only a confirmed match gets a price; "none match" stays ₱?.
        if (cands.isNotEmpty) {
          if (!mounted) return;
          setState(() => _detectStatus =
              'Comparing ${cands.length} cards with the store pictures…');
          var compared = <int>{};
          try {
            final res = await _recognizer.choosePrints(
              photo,
              {
                for (final e in cands.entries)
                  e.key: (pile: piles[e.key], prints: e.value),
              },
              apiKey: _s.anthropicApiKey,
              model: _s.visionModel,
              sellerHint: _setHint.text,
              learnedPicture: _learned.pictureFor,
            );
            prices.addAll(res.chosen);
            compared = res.compared;
          } catch (_) {}
          // No store pictures (or the check failed): best guess instead.
          for (final e in cands.entries) {
            if (!compared.contains(e.key) && !prices.containsKey(e.key)) {
              prices[e.key] = e.value.first;
            }
          }
        }
      }

      DebugLog.text(
          'summary.tsv',
          [
            for (var i = 0; i < piles.length; i++)
              [
                i,
                piles[i].code,
                piles[i].name,
                'parallel=${piles[i].parallel}',
                'sp=${piles[i].sp}',
                'qty=${piles[i].qty}',
                '-> ${prices[i]?.code ?? '-'} ${prices[i]?.rarity ?? ''} ${prices[i]?.sourcePrice ?? ''}',
              ].join('\t'),
          ].join('\n'));

      final newTags = <PriceTag>[];
      for (var i = 0; i < piles.length; i++) {
        final pile = piles[i];
        final r = prices[i];
        newTags.add(PriceTag(
          id: '${_nextId++}',
          pos: Offset(pile.x, pile.y),
          pricePhp: r == null ? null : computePhp(r, _s),
          qty: pile.qty,
          cardName: r?.name ?? pile.name,
          code: r?.code ?? pile.code,
          rarity: r == null
              ? ''
              : [r.rarity, r.variant].where((x) => x.isNotEmpty).join(' '),
          source: r,
          needsReview: true,
          readName: pile.name,
          readCode: pile.code,
          readW: pile.w,
          readH: pile.h,
        ));
      }
      if (!mounted) return;
      setState(() {
        // Replace unchecked tags from an earlier auto-detect run; keep tags
        // you added or already checked/edited.
        _tags.removeWhere((t) => t.needsReview);
        _tags.addAll(newTags);
      });
      final missing = piles.length - prices.length;
      final spNoHint = hintSets.isEmpty &&
          game.yuyuteiSlug != null &&
          piles.any((p) => p.sp);
      _snack('Detected ${piles.length} piles, priced ${prices.length}'
          '${missing > 0 ? ', $missing need a price (₱?)' : ''}. '
          '${spNoHint ? 'SP cards found: type the set they came from in "Set hint" (e.g. EB05) and run again. ' : ''}'
          'Orange tags are auto-detected: double-click to check or fix.');
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
  }

  void _deleteTag(PriceTag t) => setState(() {
        _tags.remove(t);
        if (_selectedId == t.id) _selectedId = null;
      });

  void _recalculate() {
    var n = 0;
    setState(() {
      for (final t in _tags) {
        final src = t.source;
        if (src == null) continue;
        t.pricePhp = computePhp(src, _s);
        n++;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(n == 0
          ? 'No auto-priced tags to update (hand-typed prices stay as they are).'
          : 'Updated $n tag${n == 1 ? '' : 's'} with the current settings.'),
    ));
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyO, control: true):
            _openPhoto,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _export,
        const SingleActivator(LogicalKeyboardKey.delete): () {
          final t = _tags.where((t) => t.id == _selectedId).firstOrNull;
          if (t != null) _deleteTag(t);
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Row(
            children: [
              Expanded(child: _buildCanvas(context)),
              const VerticalDivider(width: 1),
              SizedBox(width: 380, child: _buildSidePanel(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCanvas(BuildContext context) {
    final image = _image;
    if (image == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.style_outlined, size: 72),
            const SizedBox(height: 12),
            const Text('Open a photo of the cards you are selling'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _openPhoto,
              icon: const Icon(Icons.folder_open),
              label: const Text('Open photo  (Ctrl+O)'),
            ),
          ],
        ),
      );
    }

    return Container(
      color: const Color(0xFF1E1E1E),
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(builder: (context, box) {
        // Fit the image inside the available space (like BoxFit.contain).
        final iw = image.width.toDouble(), ih = image.height.toDouble();
        final scale = (box.maxWidth / iw) < (box.maxHeight / ih)
            ? box.maxWidth / iw
            : box.maxHeight / ih;
        final dw = iw * scale, dh = ih * scale;
        final fontSize = dw * kTagFontFraction * _s.tagScale;

        return Center(
          child: SizedBox(
            width: dw,
            height: dh,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onTapUp: (d) => _addTagAt(Offset(
                      d.localPosition.dx / dw,
                      d.localPosition.dy / dh,
                    )),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.precise,
                      child: Image.memory(_imageBytes!,
                          fit: BoxFit.fill, gaplessPlayback: true),
                    ),
                  ),
                ),
                for (final t in _tags) _buildTag(t, dw, dh, fontSize),
                if (_detecting)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Colors.black54,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 16),
                            Text(_detectStatus,
                                style: const TextStyle(color: Colors.white)),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      }),
    );
  }

  Widget _buildTag(PriceTag t, double dw, double dh, double fontSize) {
    final text = tagText(t, _s);
    final size = measureTag(text, fontSize);
    // Extra room so the selection outline and shadow aren't clipped.
    final hit = Size(size.width + fontSize * 0.4, size.height + fontSize * 0.4);
    return Positioned(
      left: t.pos.dx * dw - hit.width / 2,
      top: t.pos.dy * dh - hit.height / 2,
      width: hit.width,
      height: hit.height,
      child: MouseRegion(
        cursor: SystemMouseCursors.move,
        child: Tooltip(
          message: [t.cardName, t.code, t.rarity]
                  .where((s) => s.isNotEmpty)
                  .join(' · ')
                  .ifEmpty('Price tag'),
          waitDuration: const Duration(milliseconds: 600),
          child: GestureDetector(
            onTap: () => setState(() => _selectedId = t.id),
            onDoubleTap: () => _editTag(t),
            onSecondaryTap: () => _deleteTag(t),
            onPanStart: (_) => setState(() => _selectedId = t.id),
            onPanUpdate: (d) => setState(() {
              t.pos = Offset(
                (t.pos.dx + d.delta.dx / dw).clamp(0.0, 1.0),
                (t.pos.dy + d.delta.dy / dh).clamp(0.0, 1.0),
              );
            }),
            child: CustomPaint(
              painter: TagPainter(
                text: text,
                fontSize: fontSize,
                background: Color(_s.tagColor),
                textColor: Color(_s.tagTextColor),
                selected: t.id == _selectedId,
                needsReview: t.needsReview,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSidePanel(BuildContext context) {
    final theme = Theme.of(context);
    final hasImage = _image != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text('TCG Price Tagger', style: theme.textTheme.titleLarge),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _openPhoto,
                icon: const Icon(Icons.folder_open),
                label: const Text('Open'),
              ),
              FilledButton.icon(
                onPressed: hasImage ? _export : null,
                icon: const Icon(Icons.save_alt),
                label: const Text('Export PNG'),
              ),
              OutlinedButton.icon(
                onPressed: _tags.isEmpty ? null : _copySummary,
                icon: const Icon(Icons.copy),
                label: const Text('Copy list'),
              ),
              FilledButton.tonalIcon(
                onPressed: hasImage && !_detecting ? _autoDetect : null,
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Auto-detect prices'),
              ),
              TextButton.icon(
                onPressed: _tags.isEmpty || _detecting ? null : _clearTags,
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('Clear tags'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: TextField(
            controller: _setHint,
            onChanged: (t) {
              _s.setHint = t.trim();
              _s.save();
            },
            decoration: const InputDecoration(
              labelText: 'Set / pack hint for Auto-detect (optional)',
              hintText: 'e.g. EB05   or   EX Vol.5   or   EB05, OP14',
              helperText: 'Set codes or words from the product name. '
                  'Needed for SP and promo cards.',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            hasImage
                ? 'Click a card to add a price. Drag tags to move them. '
                    'Double-click to edit, right-click or Delete to remove.'
                : 'Open a photo to start.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        const Divider(),
        Expanded(
          child: _tags.isEmpty
              ? Center(
                  child: Text('No tags yet',
                      style: TextStyle(color: theme.hintColor)))
              : ListView.builder(
                  itemCount: _tags.length,
                  itemBuilder: (_, i) {
                    final t = _tags[i];
                    final sub = [t.code, t.rarity]
                        .where((s) => s.isNotEmpty)
                        .join(' · ');
                    return ListTile(
                      dense: true,
                      selected: t.id == _selectedId,
                      leading: CircleAvatar(
                        radius: 14,
                        backgroundColor:
                            t.needsReview ? Colors.orange.shade700 : null,
                        child: Text('${i + 1}',
                            style: const TextStyle(fontSize: 12)),
                      ),
                      title: Text(t.cardName.isEmpty
                          ? (t.code.isEmpty ? 'Card' : t.code)
                          : t.cardName),
                      subtitle: Text(
                        [
                          if (sub.isNotEmpty) sub,
                          if (t.needsReview) 'auto-detected, check',
                          if (t.source == null && t.pricePhp != null)
                            'manual price',
                        ].join('  ·  '),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(tagText(t, _s),
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                          IconButton(
                            tooltip: 'Delete',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => _deleteTag(t),
                          ),
                        ],
                      ),
                      onTap: () => _editTag(t),
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Text('${totalQty(_tags)} cards',
                  style: theme.textTheme.bodyMedium),
              const Spacer(),
              Text(
                'Total ${_s.currencySymbol}${formatThousands(totalPhp(_tags))}',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        SettingsPanel(
          settings: _s,
          onChanged: () {
            _s.save();
            setState(() {});
          },
          onRecalculate: _tags.isEmpty ? null : _recalculate,
          learnedCount: _learnedCount,
          onForgetLearned: () async {
            await _learned.clear();
            if (!mounted) return;
            setState(() => _learnedCount = 0);
            _snack('Forgot all learned cards.');
          },
          onRefreshCatalog: () async {
            await _tcgcsv.clearCache();
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text(
                    'TCGplayer prices will be re-downloaded on the next Riftbound search.')));
          },
        ),
      ],
    );
  }
}
