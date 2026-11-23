import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../settings.dart';

class SettingsPanel extends StatefulWidget {
  const SettingsPanel({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.onRecalculate,
    required this.onRefreshCatalog,
    this.learnedCount = 0,
    this.onForgetLearned,
  });

  final AppSettings settings;
  final VoidCallback onChanged;
  final VoidCallback? onRecalculate;
  final VoidCallback onRefreshCatalog;
  final int learnedCount;
  final VoidCallback? onForgetLearned;

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  static const _swatches = <int>[
    0xE6D32F2F, // red
    0xE61565C0, // blue
    0xE62E7D32, // green
    0xE6212121, // black
    0xE6F9A825, // amber
    0xE66A1B9A, // purple
  ];

  AppSettings get s => widget.settings;

  Widget _numberField(
    String label,
    double value,
    void Function(double) onSet, {
    String? helper,
  }) {
    return TextFormField(
      initialValue: _trim(value),
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
      onChanged: (t) {
        final v = double.tryParse(t);
        if (v != null && v > 0) {
          onSet(v);
          widget.onChanged();
        }
      },
    );
  }

  static String _trim(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 460),
      child: SingleChildScrollView(
        child: ExpansionTile(
          title: const Text('Pricing & tag settings'),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Row(children: [
              Expanded(
                child: _numberField(
                  'Yuyu-tei ×',
                  s.yuyuteiMultiplier,
                  (v) => s.yuyuteiMultiplier = v,
                  helper: '¥ × this = ₱',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _numberField(
                  'USD → PHP',
                  s.usdToPhp,
                  (v) => s.usdToPhp = v,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _numberField(
                  'TCGplayer ×',
                  s.tcgplayerMultiplier,
                  (v) => s.tcgplayerMultiplier = v,
                ),
              ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              const Text('Round to nearest'),
              const SizedBox(width: 12),
              DropdownButton<int>(
                value: s.roundTo,
                items: const [1, 5, 10, 20, 50, 100]
                    .map((v) => DropdownMenuItem(
                        value: v, child: Text(v == 1 ? '₱1' : '₱$v')))
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => s.roundTo = v);
                  widget.onChanged();
                },
              ),
              const Spacer(),
              TextButton(
                onPressed: widget.onRecalculate,
                child: const Text('Recalculate tags'),
              ),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              const Text('Tag size'),
              Expanded(
                child: Slider(
                  value: s.tagScale,
                  min: 0.4,
                  max: 2.5,
                  onChanged: (v) {
                    setState(() => s.tagScale = v);
                    widget.onChanged();
                  },
                ),
              ),
            ]),
            Row(children: [
              const Text('Tag color'),
              const SizedBox(width: 12),
              for (final c in _swatches)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: InkWell(
                    onTap: () {
                      setState(() => s.tagColor = c);
                      widget.onChanged();
                    },
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                          width: s.tagColor == c ? 3 : 1,
                          color: s.tagColor == c
                              ? Colors.yellowAccent
                              : Colors.white70,
                        ),
                      ),
                    ),
                  ),
                ),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Show quantity on tag (×2)'),
              value: s.showQtyOnTag,
              onChanged: (v) {
                setState(() => s.showQtyOnTag = v);
                widget.onChanged();
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Add total banner to exported photo'),
              value: s.exportTotal,
              onChanged: (v) {
                setState(() => s.exportTotal = v);
                widget.onChanged();
              },
            ),
            const SizedBox(height: 8),
            TextFormField(
              initialValue: s.anthropicApiKey,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Claude API key (for Auto-detect)',
                helperText: 'From console.anthropic.com. Stored on this PC only.',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (t) {
                s.anthropicApiKey = t.trim();
                widget.onChanged();
              },
            ),
            const SizedBox(height: 8),
            TextFormField(
              initialValue: s.visionModel,
              decoration: const InputDecoration(
                labelText: 'Vision model',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (t) {
                if (t.trim().isEmpty) return;
                s.visionModel = t.trim();
                widget.onChanged();
              },
            ),
            const SizedBox(height: 8),
            TextFormField(
              initialValue: s.riftboundCategory,
              decoration: const InputDecoration(
                labelText: 'Riftbound category name on TCGplayer',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (t) {
                if (t.trim().isEmpty) return;
                s.riftboundCategory = t.trim();
                widget.onChanged();
              },
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: widget.onRefreshCatalog,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Refresh TCGplayer prices now'),
              ),
            ),
            Row(children: [
              Expanded(
                child: Text(
                  'Learned cards: ${widget.learnedCount}\n'
                  'Fix or confirm an orange tag to teach auto-detect.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              TextButton(
                onPressed: widget.learnedCount == 0
                    ? null
                    : () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: const Text('Forget learned cards?'),
                            content: Text(
                                'This removes all ${widget.learnedCount} cards '
                                'auto-detect learned from your corrections.'),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(c, false),
                                  child: const Text('Cancel')),
                              FilledButton(
                                  onPressed: () => Navigator.pop(c, true),
                                  child: const Text('Forget')),
                            ],
                          ),
                        );
                        if (ok == true) widget.onForgetLearned?.call();
                      },
                child: const Text('Forget'),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
