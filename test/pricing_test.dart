import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tcg_price_tagger/models.dart';
import 'package:tcg_price_tagger/pricing.dart';
import 'package:tcg_price_tagger/services/yuyutei_service.dart';
import 'package:tcg_price_tagger/settings.dart';

void main() {
  group('pricing', () {
    test('Yuyu-tei yen × 0.35', () {
      const r = PriceResult(
        game: Game.onePiece,
        code: 'EB05-061',
        name: 'Nami',
        rarity: 'SEC',
        sourcePrice: 1480,
        currency: 'JPY',
        sourceUrl: '',
      );
      expect(computePhp(r, AppSettings()), 518);
    });

    test('TCGplayer USD × rate', () {
      const r = PriceResult(
        game: Game.riftbound,
        code: 'OGN 175/298',
        name: 'Noxus Hopeful',
        rarity: 'Common',
        sourcePrice: 0.66,
        currency: 'USD',
        sourceUrl: '',
      );
      expect(computePhp(r, AppSettings(usdToPhp: 58)), 38);
      expect(computePhp(r, AppSettings(usdToPhp: 58, roundTo: 5)), 40);
    });

    test('formatThousands', () {
      expect(formatThousands(518), '518');
      expect(formatThousands(1480), '1,480');
      expect(formatThousands(1234567), '1,234,567');
    });
  });

  group('Yuyu-tei parser', () {
    final html = File('test/fixtures/yuyutei_sample.html').readAsStringSync();
    final cards = parseYuyuteiHtml(html, 'https://yuyu-tei.jp/sell/opc/s/eb05');

    test('finds every card box, including parallels', () {
      expect(cards.length, 4);
      final nami = cards.where((c) => c.code == 'EB05-061').toList();
      expect(nami.map((c) => c.rarity), ['SEC', 'P-SEC']);
      expect(nami.map((c) => c.sourcePrice), [1480, 1980]);
    });

    test('reads name, rarity and price', () {
      final alvida = cards.firstWhere((c) => c.code == 'EB05-021');
      expect(alvida.name, 'アルビダ');
      expect(alvida.rarity, 'SR');
      expect(alvida.sourcePrice, 780);
      expect(alvida.currency, 'JPY');
    });

    test('keeps each print\'s picture URL', () {
      final nami = cards.where((c) => c.code == 'EB05-061').toList();
      expect(nami[0].imageUrl, 'https://yuyu-tei.jp/sell/opc/s/x.jpg');
      expect(nami[1].imageUrl, 'https://yuyu-tei.jp/sell/opc/s/y.jpg');
    });
  });
}
