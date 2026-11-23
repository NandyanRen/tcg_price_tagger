import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class AppSettings {
  /// Yuyu-tei yen price × this = your peso price. (1,480 yen × 0.35 = ₱518)
  double yuyuteiMultiplier;

  /// TCGplayer USD × this = pesos.
  double usdToPhp;

  /// Extra multiplier on top of the converted TCGplayer price.
  double tcgplayerMultiplier;

  /// Round final prices to the nearest N pesos (1 = no rounding).
  int roundTo;

  /// Tag size relative to the image width.
  double tagScale;

  int tagColor;
  int tagTextColor;
  bool showQtyOnTag;
  bool exportTotal;
  String currencySymbol;

  /// TCGplayer category name to look up on tcgcsv.com.
  String riftboundCategory;

  Game lastGame;

  /// Claude API key for photo recognition (console.anthropic.com).
  String anthropicApiKey;
  String visionModel;

  /// Last set hint used for auto-detect (e.g. "EB05").
  String setHint;

  AppSettings({
    this.yuyuteiMultiplier = 0.35,
    this.usdToPhp = 58,
    this.tcgplayerMultiplier = 1.0,
    this.roundTo = 1,
    this.tagScale = 1.0,
    this.tagColor = 0xE6D32F2F,
    this.tagTextColor = 0xFFFFFFFF,
    this.showQtyOnTag = true,
    this.exportTotal = false,
    this.currencySymbol = '₱',
    this.riftboundCategory = 'Riftbound',
    this.lastGame = Game.onePiece,
    this.anthropicApiKey = '',
    this.visionModel = 'claude-opus-5-5',
    this.setHint = '',
  });

  Map<String, dynamic> toJson() => {
        'yuyuteiMultiplier': yuyuteiMultiplier,
        'usdToPhp': usdToPhp,
        'tcgplayerMultiplier': tcgplayerMultiplier,
        'roundTo': roundTo,
        'tagScale': tagScale,
        'tagColor': tagColor,
        'tagTextColor': tagTextColor,
        'showQtyOnTag': showQtyOnTag,
        'exportTotal': exportTotal,
        'currencySymbol': currencySymbol,
        'riftboundCategory': riftboundCategory,
        'lastGame': lastGame.name,
        'anthropicApiKey': anthropicApiKey,
        'visionModel': visionModel,
        'setHint': setHint,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) {
    final d = AppSettings();
    double dbl(String k, double def) => (j[k] as num?)?.toDouble() ?? def;
    return AppSettings(
      yuyuteiMultiplier: dbl('yuyuteiMultiplier', d.yuyuteiMultiplier),
      usdToPhp: dbl('usdToPhp', d.usdToPhp),
      tcgplayerMultiplier: dbl('tcgplayerMultiplier', d.tcgplayerMultiplier),
      roundTo: (j['roundTo'] as num?)?.toInt() ?? d.roundTo,
      tagScale: dbl('tagScale', d.tagScale),
      tagColor: (j['tagColor'] as num?)?.toInt() ?? d.tagColor,
      tagTextColor: (j['tagTextColor'] as num?)?.toInt() ?? d.tagTextColor,
      showQtyOnTag: j['showQtyOnTag'] as bool? ?? d.showQtyOnTag,
      exportTotal: j['exportTotal'] as bool? ?? d.exportTotal,
      currencySymbol: j['currencySymbol'] as String? ?? d.currencySymbol,
      riftboundCategory:
          j['riftboundCategory'] as String? ?? d.riftboundCategory,
      lastGame: Game.values.asNameMap()[j['lastGame']] ?? d.lastGame,
      anthropicApiKey: j['anthropicApiKey'] as String? ?? d.anthropicApiKey,
      visionModel: j['visionModel'] as String? ?? d.visionModel,
      setHint: j['setHint'] as String? ?? d.setHint,
    );
  }

  static const _key = 'app_settings_v1';

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return AppSettings();
    try {
      return AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return AppSettings();
    }
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(toJson()));
  }
}
