import 'package:flutter/material.dart';

/// Shared by the on-screen preview and the PNG export so they look the same.
/// Font size is always a fraction of the image width.
const double kTagFontFraction = 0.028;

TextPainter _layout(String text, double fontSize, Color textColor) {
  return TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: textColor,
        fontSize: fontSize,
        fontWeight: FontWeight.w800,
        height: 1.1,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
}

Size measureTag(String text, double fontSize) {
  final tp = _layout(text, fontSize, Colors.white);
  final pad = fontSize * 0.35;
  return Size(tp.width + pad * 2, tp.height + pad * 1.4);
}

/// Paints a rounded price tag centered on [center].
void paintTag(
  Canvas canvas,
  Offset center,
  String text,
  double fontSize, {
  required Color background,
  required Color textColor,
  bool selected = false,
  bool needsReview = false,
}) {
  final tp = _layout(text, fontSize, textColor);
  final size = measureTag(text, fontSize);
  final rect = Rect.fromCenter(
      center: center, width: size.width, height: size.height);
  final rrect = RRect.fromRectAndRadius(rect, Radius.circular(fontSize * 0.3));

  canvas.drawRRect(
    rrect.shift(Offset(0, fontSize * 0.08)),
    Paint()
      ..color = Colors.black.withValues(alpha: 0.35)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, fontSize * 0.15),
  );
  canvas.drawRRect(rrect, Paint()..color = background);
  canvas.drawRRect(
    rrect,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth =
          (selected || needsReview) ? fontSize * 0.12 : fontSize * 0.06
      ..color = selected
          ? Colors.yellowAccent
          : needsReview
              ? Colors.orangeAccent
              : Colors.white,
  );
  tp.paint(
    canvas,
    Offset(center.dx - tp.width / 2, center.dy - tp.height / 2),
  );
}

class TagPainter extends CustomPainter {
  TagPainter({
    required this.text,
    required this.fontSize,
    required this.background,
    required this.textColor,
    required this.selected,
    this.needsReview = false,
  });

  final String text;
  final double fontSize;
  final Color background;
  final Color textColor;
  final bool selected;
  final bool needsReview;

  @override
  void paint(Canvas canvas, Size size) {
    paintTag(canvas, size.center(Offset.zero), text, fontSize,
        background: background,
        textColor: textColor,
        selected: selected,
        needsReview: needsReview);
  }

  @override
  bool shouldRepaint(TagPainter old) =>
      old.text != text ||
      old.fontSize != fontSize ||
      old.background != background ||
      old.textColor != textColor ||
      old.selected != selected ||
      old.needsReview != needsReview;
}
