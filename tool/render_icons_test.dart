// Draws the app's own mark into the icon files the platforms ask for.
//
//     flutter test tool/render_icons_test.dart
//
// Writes build/icons/. Copy the results into web/ (and anywhere else an icon
// is needed) and commit them; this is a generator, not a gate, and it is not
// run by `flutter test`, which walks test/ only.
//
// It exists because there is no SVG rasteriser on the machine this repo is
// worked on. Flutter can already draw the mark and can already encode a PNG,
// so the drawing in the app is the drawing in the icon, by construction.
//
// assets/icon/launcher_icon.svg stays: it is a hand-copy of the same painter
// and it is what CI rasterises for the Android and iOS launcher icons, where
// rsvg-convert is available. Two descriptions of one mark can drift, so if
// the painter changes, redraw the SVG to match and regenerate these.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/widgets/brand_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// One icon, drawn at [size] logical pixels.
///
/// [maskable] fills the whole square and insets the mark, because Android
/// crops a maskable icon to whatever shape the launcher likes and anything
/// in the outer 10% can be cut off. The others keep the rounded square the
/// mark wears everywhere else in the app.
Widget _icon(double size, {required bool maskable}) {
  final inset = maskable ? size * 0.20 : 0.0;
  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: AppColors.deepNavy,
      borderRadius:
          maskable ? null : BorderRadius.circular(size * 0.326),
      border: maskable
          ? null
          : Border.all(color: AppColors.line, width: size * 0.0217),
    ),
    child: Padding(
      padding: EdgeInsets.all(inset),
      child: const CustomPaint(painter: CoLabRoomMarkPainter()),
    ),
  );
}

void main() {
  testWidgets('draw the icons', (tester) async {
    final targets = <({String name, double size, bool maskable})>[
      (name: 'favicon', size: 64, maskable: false),
      (name: 'Icon-192', size: 192, maskable: false),
      (name: 'Icon-512', size: 512, maskable: false),
      (name: 'Icon-maskable-192', size: 192, maskable: true),
      (name: 'Icon-maskable-512', size: 512, maskable: true),
    ];

    for (final target in targets) {
      final key = GlobalKey();
      tester.view.physicalSize = Size(target.size, target.size);
      tester.view.devicePixelRatio = 1.0;

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            key: key,
            child: _icon(target.size, maskable: target.maskable),
          ),
        ),
      );
      await tester.pump();

      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory('build/icons')..createSync(recursive: true);
        File('${dir.path}/${target.name}.png')
            .writeAsBytesSync(data!.buffer.asUint8List(), flush: true);
        // ignore: avoid_print
        print('wrote build/icons/${target.name}.png');
      });
    }
    tester.view.reset();
  });
}
