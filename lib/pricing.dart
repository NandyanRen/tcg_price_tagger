import 'models.dart';
import 'settings.dart';

/// Converts a source price to your selling price in pesos.
int computePhp(PriceResult r, AppSettings s) {
  final double raw = switch (r.currency) {
    'JPY' => r.sourcePrice * s.yuyuteiMultiplier,
    'USD' => r.sourcePrice * s.usdToPhp * s.tcgplayerMultiplier,
    _ => r.sourcePrice,
  };
  return roundToStep(raw, s.roundTo);
}

int roundToStep(double value, int step) {
  if (step <= 1) return value.round();
  return (value / step).round() * step;
}

/// 1480 -> "1,480"
String formatThousands(num value) {
  final neg = value < 0;
  final s = value.abs().round().toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return neg ? '-$buf' : buf.toString();
}

String formatSource(PriceResult r) => switch (r.currency) {
      'JPY' => '¥${formatThousands(r.sourcePrice)}',
      'USD' => '\$${r.sourcePrice.toStringAsFixed(2)}',
      _ => r.sourcePrice.toString(),
    };

String tagText(PriceTag t, AppSettings s) {
  final p = t.pricePhp;
  final price = '${s.currencySymbol}${p == null ? '?' : formatThousands(p)}';
  return (s.showQtyOnTag && t.qty > 1) ? '$price ×${t.qty}' : price;
}

int totalPhp(Iterable<PriceTag> tags) =>
    tags.fold(0, (sum, t) => sum + (t.pricePhp ?? 0) * t.qty);

int totalQty(Iterable<PriceTag> tags) => tags.fold(0, (sum, t) => sum + t.qty);
