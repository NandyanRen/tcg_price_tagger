import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'models.dart';
import 'pricing.dart';
import 'settings.dart';
import 'ui/tag_painter.dart';

/// Renders the photo with its tags at the photo's full resolution.
Future<Uint8List> renderExport(
  ui.Image image,
  List<PriceTag> tags,
  AppSettings s,
) async {
  final w = image.width.toDouble();
  final h = image.height.toDouble();
  final fontSize = w * kTagFontFraction * s.tagScale;
  final bandH = s.exportTotal && tags.isNotEmpty ? fontSize * 2.6 : 0.0;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawImage(image, Offset.zero, Paint()..filterQuality = FilterQuality.high);

  for (final t in tags) {
    paintTag(
      canvas,
      Offset(t.pos.dx * w, t.pos.dy * h),
      tagText(t, s),
      fontSize,
      background: Color(s.tagColor),
      textColor: Color(s.tagTextColor),
    );
  }

  if (bandH > 0) {
    canvas.drawRect(Rect.fromLTWH(0, h, w, bandH), Paint()..color = Colors.white);
    final tp = TextPainter(
      text: TextSpan(
        text: 'Total: ${s.currencySymbol}${formatThousands(totalPhp(tags))}'
            '  ·  ${totalQty(tags)} card${totalQty(tags) == 1 ? '' : 's'}',
        style: TextStyle(
          color: Colors.black,
          fontSize: fontSize * 1.1,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: w);
    tp.paint(canvas, Offset((w - tp.width) / 2, h + (bandH - tp.height) / 2));
  }

  final picture = recorder.endRecording();
  final out = await picture.toImage(image.width, (h + bandH).round());
  final bytes = await out.toByteData(format: ui.ImageByteFormat.png);
  picture.dispose();
  out.dispose();
  return bytes!.buffer.asUint8List();
}
