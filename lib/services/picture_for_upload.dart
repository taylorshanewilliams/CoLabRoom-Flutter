import 'dart:typed_data';
import 'dart:ui' as ui;

/// Making a photo small enough to be a picture of somebody.
///
/// A photo off a phone is three to twelve megabytes. Nothing in this app ever
/// shrank one, so the raw file went up — which was merely wasteful until the
/// avatars bucket grew a five megabyte cap, at which point ordinary phone
/// photos started being refused and the only visible symptom was an error
/// after leaving the screen.
///
/// Both halves of that were wrong. The cap is right; uploading a twelve
/// megabyte file to draw a 44-pixel circle never was. Every viewer downloads
/// it, on their data, to shrink it again on arrival.
///
/// **No new dependency.** `dart:ui` decodes whatever the platform decodes —
/// JPEG, PNG, WebP, and HEIC on the phones that produce it — and will decode
/// straight to a target size, so the full image is never held in memory at
/// full resolution. It only encodes PNG, which is larger than a JPEG of the
/// same picture and still two orders of magnitude smaller than what was
/// being sent.
class PictureForUpload {
  const PictureForUpload._();

  /// The longest side of a picture after shrinking.
  ///
  /// Drawn at 44 logical pixels on a profile and 26 in a list; 512 covers the
  /// densest screen anybody has and a viewer zooming in.
  static const int longestSide = 512;

  /// Shrinks [bytes] to something reasonable to upload and to download.
  ///
  /// Returns the original bytes when the picture cannot be decoded, rather
  /// than failing: a format this platform does not understand is a format the
  /// server may still accept, and refusing it here would turn "your phone
  /// makes HEIC" into "you cannot have a profile picture".
  static Future<Uint8List> shrink(Uint8List bytes) async {
    try {
      // Decoded once at full size only to learn its shape. `getNextFrame`
      // gives dimensions without the caller having to guess which side is
      // longer — and guessing wrong turns a portrait photo into a 512-wide,
      // 900-tall picture, which is not smaller in the way that matters.
      final probe = await ui.instantiateImageCodec(bytes);
      final first = await probe.getNextFrame();
      final width = first.image.width;
      final height = first.image.height;
      first.image.dispose();

      if (width <= longestSide && height <= longestSide) return bytes;

      final codec = width >= height
          ? await ui.instantiateImageCodec(bytes, targetWidth: longestSide)
          : await ui.instantiateImageCodec(bytes, targetHeight: longestSide);
      final frame = await codec.getNextFrame();
      final data =
          await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      if (data == null) return bytes;

      final shrunk = data.buffer.asUint8List();
      // Only if it actually helped. A small PNG re-encoded can come out
      // bigger than the JPEG it started as, and sending the larger of the two
      // would be the opposite of the point.
      return shrunk.length < bytes.length ? shrunk : bytes;
    } catch (_) {
      return bytes;
    }
  }
}
