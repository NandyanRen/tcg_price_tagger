import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// While running with `flutter run` (debug mode), saves what auto-detect
/// saw and received to <project>/debug_last_run/ so problems can be traced.
/// Does nothing in release builds.
class DebugLog {
  static Directory? _dir;
  static int _seq = 0;

  static Future<void> start() async {
    if (!kDebugMode) return;
    try {
      final dir = Directory('${Directory.current.path}${Platform.pathSeparator}debug_last_run');
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.create(recursive: true);
      _dir = dir;
      _seq = 0;
    } catch (_) {
      _dir = null;
    }
  }

  static String _name(String name) =>
      '${(++_seq).toString().padLeft(3, '0')}_$name';

  static void text(String name, String content) {
    final d = _dir;
    if (d == null) return;
    try {
      File('${d.path}${Platform.pathSeparator}${_name(name)}')
          .writeAsStringSync(content);
    } catch (_) {}
  }

  static void bytes(String name, Uint8List content) {
    final d = _dir;
    if (d == null) return;
    try {
      File('${d.path}${Platform.pathSeparator}${_name(name)}')
          .writeAsBytesSync(content);
    } catch (_) {}
  }
}
