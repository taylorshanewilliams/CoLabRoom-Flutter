import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// The browser tab shows CoLabRoom, not Flutter.
///
/// Taylor, on the deployed web app: "the logo that is on the top of the web
/// browser is wrong, its the very old icon." It was worse than old — it was
/// the Flutter SDK's own logo, blue on white, which `flutter create` writes
/// into `web/` and which nothing had replaced since the folder was
/// bootstrapped on 24 August. It served on app.colabroom.com for three weeks.
///
/// Nothing caught it because nothing had ever looked at a file that is not
/// Dart. This looks: the icons are drawn from `CoLabRoomMarkPainter` by
/// `tool/render_icons_test.dart`, and the app's mark sits on
/// `AppColors.deepNavy`, while Flutter's placeholder sits on white.
Future<Uint8List> _pixels(String path) async {
  final bytes = await File(path).readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final data =
      await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List();
}

/// The middle of the top edge, just inside the shape.
///
/// Deliberately above the arc: the ring's top sits at 17% of the height, so
/// a sample any lower reads the cyan stroke in both icons and distinguishes
/// nothing. At 5% it is the background, which is the thing that differs.
({int r, int g, int b, int a}) _sample(Uint8List pixels, int width, int y) {
  final index = ((y * width) + (width ~/ 2)) * 4;
  return (
    r: pixels[index],
    g: pixels[index + 1],
    b: pixels[index + 2],
    a: pixels[index + 3],
  );
}

void main() {
  for (final icon in <({String path, int width})>[
    (path: 'web/favicon.png', width: 64),
    (path: 'web/icons/Icon-192.png', width: 192),
    (path: 'web/icons/Icon-512.png', width: 512),
    (path: 'web/icons/Icon-maskable-192.png', width: 192),
    (path: 'web/icons/Icon-maskable-512.png', width: 512),
  ]) {
    test('${icon.path} is ours, not the SDK placeholder', () async {
      expect(File(icon.path).existsSync(), isTrue,
          reason: '${icon.path} is referenced by index.html or manifest.json');

      final pixels = await _pixels(icon.path);
      final sample = _sample(pixels, icon.width, (icon.width * 0.05).round());

      // Flutter's placeholder is a blue glyph on white with a transparent
      // surround; ours is a mark on near-black. Either of those two failures
      // is the one that happened.
      expect(sample.a, greaterThan(200),
          reason: 'the placeholder is transparent where ours is painted');
      expect(
        sample.r + sample.g + sample.b,
        lessThan(180),
        reason: 'AppColors.deepNavy is 0x06101F — anything bright here is '
            'the white square Flutter ships',
      );
    });
  }
}
