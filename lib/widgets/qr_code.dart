import 'package:barcode/barcode.dart';
import 'package:flutter/material.dart';

/// A QR code, drawn by the app rather than fetched from anywhere.
///
/// Black on white whatever the theme, with the quiet margin a phone camera
/// needs to find the edges -- a code on the app's navy would look right and
/// scan badly. Medium error correction, so a poster with a thumbtack through
/// one corner still opens.
class QrCode extends StatelessWidget {
  const QrCode({required this.data, this.size = 220, this.label, super.key});

  final String data;
  final double size;

  /// What it opens, for a screen reader: the code itself says nothing.
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label ?? 'QR code',
      image: true,
      child: Container(
        padding: EdgeInsets.all(size * 0.06),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: CustomPaint(
          size: Size.square(size),
          painter: _QrPainter(data),
        ),
      ),
    );
  }
}

/// The dark modules of [data]'s QR code, laid out in a square of [size].
/// Kept apart from the painter so a test can check there is a code at all.
Iterable<BarcodeBar> qrModules(String data, double size) => Barcode.qrCode(
      errorCorrectLevel: BarcodeQRCorrectionLevel.medium,
    ).make(data, width: size, height: size).whereType<BarcodeBar>().where((bar) => bar.black);

class _QrPainter extends CustomPainter {
  const _QrPainter(this.data);

  final String data;

  @override
  void paint(Canvas canvas, Size size) {
    // Not anti-aliased: softened edges between neighbouring modules draw
    // hairline seams, and seams are what a camera trips on.
    final paint = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (final bar in qrModules(data, size.width)) {
      canvas.drawRect(Rect.fromLTWH(bar.left, bar.top, bar.width, bar.height), paint);
    }
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) => oldDelegate.data != data;
}
