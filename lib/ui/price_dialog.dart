import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../pricing.dart';
import '../services/auto_pricer.dart';
import '../services/tcgcsv_service.dart';
import '../services/yuyutei_service.dart';
import '../settings.dart';

/// What the dialog hands back to the editor.
class PriceDialogResult {
  final int pricePhp;
  final int qty;
  final String cardName;
  final String code;
  final String rarity;
  final PriceResult? source;

  const PriceDialogResult({
    required this.pricePhp,
    required this.qty,
    required this.cardName,
    required this.code,
    required this.rarity,
    this.source,
  });
}

class PriceDialog extends StatefulWidget {
  const PriceDialog({
    super.key,
    required this.settings,
    required this.yuyutei,
    required this.tcgcsv,
    this.initial,
  });

  final AppSettings settings;
  final YuyuteiService yuyutei;
  final TcgCsvService tcgcsv;
  final PriceTag? initial;

  static Future<PriceDialogResult?> show(
    BuildContext context, {
    required AppSettings settings,
    required YuyuteiService yuyutei,
    required TcgCsvService tcgcsv,
    PriceTag? initial,
  }) {
    return showDialog<PriceDialogResult>(
      context: context,
      builder: (_) => PriceDialog(
        settings: settings,
        yuyutei: yuyutei,
        tcgcsv: tcgcsv,
        initial: initial,
      ),
    );
  }

  @override
  State<PriceDialog> createState() => _PriceDialogState();
}

class _PriceDialogState extends State<PriceDialog> {
  late Game _game;
  final _query = TextEditingController();
  final _price = TextEditingController();
  final _qty = TextEditingController(text: '1');
  final _name = TextEditingController();
  final _queryFocus = FocusNode();

  List<PriceResult> _results = [];
  PriceResult? _selected;
  String _code = '';
  String _rarity = '';
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final t = widget.initial;
    _game = t?.source?.game ?? widget.settings.lastGame;
    if (t != null) {
      _price.text = t.pricePhp?.toString() ?? '';
      _qty.text = t.qty.toString();
      _name.text = t.cardName;
      _code = t.code;
      _rarity = t.rarity;
      _selected = t.source;
      _query.text = _initialQuery(t);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queryFocus.requestFocus();
      // Auto-detected tag that couldn't be priced: search right away.
      if (t != null && t.pricePhp == null && _query.text.isNotEmpty) {
        _search();
      }
    });
  }

  String _initialQuery(PriceTag t) {
    if (_game == Game.riftbound) return t.cardName;
    if (YuyuteiService.setOf(t.code) != null) return t.code; // full code
    final set = AutoPricer.setPrefix(t.code);
    if (set != null && t.cardName.isNotEmpty) return '$set ${t.cardName}';
    return t.code.isNotEmpty ? t.code : t.cardName;
  }

  @override
  void dispose() {
    _query.dispose();
    _price.dispose();
    _qty.dispose();
    _name.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _results = [];
    });
    try {
      final results = switch (_game) {
        Game.onePiece || Game.digimon => await widget.yuyutei.lookup(_game, q),
        Game.riftbound =>
          await widget.tcgcsv.search(q, widget.settings.riftboundCategory),
      };
      setState(() {
        _results = results;
        if (results.isEmpty) _error = 'No matches for "$q".';
      });
      if (results.length == 1) _pick(results.first);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _pick(PriceResult r) {
    setState(() {
      _selected = r;
      _price.text = computePhp(r, widget.settings).toString();
      _name.text = r.name;
      _code = r.code;
      _rarity = [r.rarity, r.variant].where((s) => s.isNotEmpty).join(' ');
    });
  }

  void _save() {
    final price = int.tryParse(_price.text.replaceAll(',', '').trim());
    if (price == null) {
      setState(() => _error = 'Enter a price, or search and pick a card.');
      return;
    }
    final qty = int.tryParse(_qty.text.trim()) ?? 1;
    // Keep the source only if the price still matches it, so a hand-edited
    // price isn't overwritten by "Recalculate".
    final src = _selected;
    final keepSource =
        src != null && computePhp(src, widget.settings) == price;
    widget.settings.lastGame = _game;
    widget.settings.save();
    Navigator.of(context).pop(PriceDialogResult(
      pricePhp: price,
      qty: qty < 1 ? 1 : qty,
      cardName: _name.text.trim(),
      code: _code,
      rarity: _rarity,
      source: keepSource ? src : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.initial == null ? 'Add price' : 'Edit price'),
      content: SizedBox(
        width: 560,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<Game>(
              segments: [
                for (final g in Game.values)
                  ButtonSegment(
                      value: g,
                      label: Text(g.label),
                      tooltip: 'Prices from ${g.sourceName}'),
              ],
              selected: {_game},
              onSelectionChanged: (v) => setState(() {
                _game = v.first;
                _results = [];
                _error = null;
              }),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _query,
                  focusNode: _queryFocus,
                  decoration: InputDecoration(
                    labelText: _game.searchHint,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _loading ? null : _search,
                icon: const Icon(Icons.search),
                label: const Text('Find price'),
              ),
            ]),
            if (_game == Game.riftbound)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'The first Riftbound search downloads the catalog (a few seconds). '
                  'After that it is cached for 12 hours.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(_error!,
                    style: TextStyle(color: theme.colorScheme.error)),
              ),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: theme.dividerColor),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: _results.isEmpty
                    ? Center(
                        child: Text(
                          'Search for a card, or just type the price below.',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: theme.hintColor),
                        ),
                      )
                    : ListView.separated(
                        itemCount: _results.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final r = _results[i];
                          final php = computePhp(r, s);
                          final sub = [
                            r.code,
                            r.rarity,
                            r.variant,
                          ].where((x) => x.isNotEmpty).join(' · ');
                          return ListTile(
                            dense: true,
                            selected: identical(r, _selected),
                            title: Text(r.name.isEmpty ? r.code : r.name),
                            subtitle: Text(sub),
                            trailing: Text(
                              '${formatSource(r)}  →  ${s.currencySymbol}${formatThousands(php)}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600),
                            ),
                            onTap: () => _pick(r),
                          );
                        },
                      ),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Card name (for your list)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 120,
                child: TextField(
                  controller: _price,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[\d,]'))
                  ],
                  decoration: InputDecoration(
                    labelText: 'Price',
                    prefixText: s.currencySymbol,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _save(),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 70,
                child: TextField(
                  controller: _qty,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Qty',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _save(),
                ),
              ),
            ]),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save tag')),
      ],
    );
  }
}
