import 'package:flutter_test/flutter_test.dart';
import 'package:tcg_price_tagger/models.dart';
import 'package:tcg_price_tagger/services/auto_pricer.dart';
import 'package:tcg_price_tagger/services/card_recognizer.dart';
import 'package:tcg_price_tagger/services/yuyutei_service.dart';

PriceResult _r(String code, String name, String rarity, double yen) =>
    PriceResult(
      game: Game.digimon,
      code: code,
      name: name,
      rarity: rarity,
      sourcePrice: yen,
      currency: 'JPY',
      sourceUrl: '',
    );

void main() {
  test('namesMatch ignores parallel suffix, spaces and width', () {
    expect(namesMatch('エグザモン(パラレル)', 'エグザモン'), isTrue);
    expect(namesMatch('結城ダン&結城カノン', '結城ダン＆結城カノン'), isTrue);
    expect(namesMatch('Ｌｕｎａｍｏｎ', 'Lunamon'), isTrue);
    expect(namesMatch('ゲコモン', 'コロナモン'), isFalse);
    expect(namesMatch('', 'コロナモン'), isFalse);
  });

  test('pickPrint chooses regular or parallel', () {
    final regular = _r('BT23-047', 'エグザモン', 'SR', 780);
    final parallel = _r('BT23-047', 'エグザモン(パラレル)', 'P-SR', 5980);
    expect(pickPrint([regular, parallel], parallel: false), same(regular));
    expect(pickPrint([regular, parallel], parallel: true), same(parallel));
    // Falls back to whatever exists.
    expect(pickPrint([regular], parallel: true), same(regular));
  });

  test('normalizeCode and setOf', () {
    expect(YuyuteiService.normalizeCode(' bt23 - 075 '), 'BT23-075');
    expect(YuyuteiService.normalizeCode('BT23–075'), 'BT23-075');
    expect(YuyuteiService.setOf('BT23-075'), 'BT23');
    expect(YuyuteiService.setOf('EX10-012'), 'EX10');
    expect(YuyuteiService.setOf('Lunamon'), isNull);
  });

  group('matching in a set', () {
    final set = [
      _r('EB05-061', 'ナミ', 'SEC', 1480),
      _r('EB05-061', 'ナミ(パラレル)', 'P-SEC', 1980),
      _r('EB05-055', 'ナミ', 'SR', 320),
      _r('EB05-006', 'ミス・バッキンガム・ステューシー', 'SR', 320),
      _r('EB05-012', 'ジュエリー・ボニー', 'SR', 500),
    ];

    test('partial code still gives the set', () {
      expect(AutoPricer.setPrefix('EB05-'), 'EB05');
      expect(AutoPricer.setPrefix('eb05-06'), 'EB05');
      expect(AutoPricer.setPrefix(''), isNull);
    });

    test('misread code falls back to the name', () {
      final m = matchInSet(set, code: 'EB05-', name: 'ジュエリー・ボニー')!;
      expect(m.single.code, 'EB05-012');
      final m2 = matchInSet(set, code: 'EB05-009', name: 'ミス・バッキンガム・ステューシ')!;
      expect(m2.single.code, 'EB05-006');
    });

    test('misread code that belongs to another card is not trusted', () {
      expect(matchInSet(set, code: 'EB05-055', name: 'コーザ'), isNull);
    });

    test('ambiguous name with a misread code is left unresolved', () {
      expect(matchInSet(set, code: 'EB05-065', name: 'ナミ'), isNull);
    });

    test('correct code returns all prints', () {
      final m = matchInSet(set, code: 'EB05-061', name: 'ナミ')!;
      expect(m.length, 2);
      expect(pickPrint(m, parallel: true).rarity, 'P-SEC');
    });
  });

  group('SP reprints', () {
    final eb05 = [
      _r('OP14-033', 'ペローナ(パラレル)', 'SP', 12800),
      _r('EB05-031', 'ヴィンスモーク・レイジュ(パラレル)', 'SP', 19800),
      _r('EB05-031', 'ヴィンスモーク・レイジュ', 'SR', 300),
      _r('EB05-031', 'ヴィンスモーク・レイジュ(パラレル)', 'P-SR', 1980),
    ];

    test('set hint parsing', () {
      expect(AutoPricer.parseSetHint('eb05, op14'), ['EB05', 'OP14']);
      expect(AutoPricer.parseSetHint(''), isEmpty);
    });

    test('old code found on the hinted set page as SP', () {
      final m = matchInSet(eb05, code: 'OP14-033', name: 'ペローナ')!;
      expect(m.single.rarity, 'SP');
    });

    test('pickPrint prefers SP when flagged', () {
      final reiju = eb05.where((c) => c.code == 'EB05-031').toList();
      expect(pickPrint(reiju, parallel: true, sp: true).rarity, 'SP');
      expect(pickPrint(reiju, parallel: true).rarity, 'P-SR');
      expect(pickPrint(reiju, parallel: false).rarity, 'SR');
    });
  });

  test('candidatesFor puts hinted-set SP first for an SP pile', () {
    PriceResult at(String set, String code, String name, String rarity) =>
        PriceResult(
          game: Game.onePiece,
          code: code,
          name: name,
          rarity: rarity,
          sourcePrice: 1,
          currency: 'JPY',
          sourceUrl: 'https://yuyu-tei.jp/sell/opc/s/$set',
        );
    final all = [
      at('op14', 'OP14-112', 'シャーロット・プリン(パラレル)', 'SP'),
      at('op11', 'OP11-070', 'シャーロット・プリン', 'SR'),
      at('eb05', 'OP17-109', 'シャーロット・プリン(パラレル)', 'SP'),
      at('eb05', 'EB05-001', 'ジュエリー・ボニー', 'SR'),
    ];
    const pile = DetectedPile(
        code: 'OP14-112',
        name: 'シャーロット・プリン',
        parallel: true,
        sp: true,
        qty: 1,
        x: 0,
        y: 0);
    final c = candidatesFor(pile, all, hintSets: ['EB05']);
    expect(c.first.code, 'OP17-109');
    expect(c.length, 3);
  });

  group('pack hint', () {
    test('splits set codes from name keywords', () {
      expect(AutoPricer.parseSetHint('EB05, EX Vol.5'), ['EB05']);
      expect(AutoPricer.parseHintKeywords('EB05, EX Vol.5'), ['EX Vol.5']);
      expect(AutoPricer.parseSetHint('EB05 OP14'), ['EB05', 'OP14']);
      expect(AutoPricer.parseSetHint('promo-op20'), ['PROMO-OP20']);
      expect(AutoPricer.parseHintKeywords('promo-op20'), isEmpty);
    });

    test('promo listing named in the hint ranks first', () {
      PriceResult at(String name, double yen) => PriceResult(
            game: Game.onePiece,
            code: 'OP11-107',
            name: name,
            rarity: 'C',
            sourcePrice: yen,
            currency: 'JPY',
            sourceUrl: 'https://yuyu-tei.jp/sell/opc/s/search?search_word=OP11-107',
          );
      final all = [
        at('チョンマゲ', 50),
        at('チョンマゲ(パラレル）(プロモーションパックEX Vol.5)', 1280),
      ];
      const pile = DetectedPile(
          code: 'OP11-107',
          name: 'チョンマゲ',
          parallel: false,
          qty: 5,
          x: 0,
          y: 0);
      final c = candidatesFor(pile, all, hintKeywords: ['EX Vol.5']);
      expect(c.first.sourcePrice, 1280);
      // Without the hint the regular card ranks first.
      expect(candidatesFor(pile, all).first.sourcePrice, 50);
    });
  });
}
