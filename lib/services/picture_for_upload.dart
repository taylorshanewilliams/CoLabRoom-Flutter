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

  /// The same, for a picture going on a profile's gallery (0171).
  ///
  /// Two differences, both because of what a gallery picture is: a photograph
  /// of a place, on a page strangers read, rather than a face in a circle.
  ///
  /// It **always** re-encodes, even when the picture is already small enough.
  /// [shrink] hands back the original bytes untouched in that case, and the
  /// original bytes of a phone photo carry EXIF — which on an ordinary snap
  /// means the time it was taken and very often where. Decoding to pixels and
  /// encoding a fresh PNG leaves that behind. Nothing is inferred about a
  /// person in this app (Every Musician, Same Song, 17 September 2026), and a
  /// photograph that quietly carried a house's coordinates onto a profile
  /// would be the largest inference of all.
  ///
  /// And it **refuses** rather than falling back. A picture this phone cannot
  /// decode is one it cannot strip, and a gallery can do without a picture in
  /// a format nobody here can read.
  static Future<Uint8List> forGallery(Uint8List bytes) async {
    final ui.Codec codec;
    try {
      final probe = await ui.instantiateImageCodec(bytes);
      final first = await probe.getNextFrame();
      final width = first.image.width;
      final height = first.image.height;
      first.image.dispose();

      codec = width <= longestSide && height <= longestSide
          ? await ui.instantiateImageCodec(bytes)
          : width >= height
              ? await ui.instantiateImageCodec(bytes, targetWidth: longestSide)
              : await ui.instantiateImageCodec(bytes, targetHeight: longestSide);
    } catch (_) {
      throw const PictureThisPhoneCannotRead();
    }

    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    if (data == null) throw const PictureThisPhoneCannotRead();
    return data.buffer.asUint8List();
  }
}

/// Said in words somebody can act on: try a different picture.
class PictureThisPhoneCannotRead implements Exception {
  const PictureThisPhoneCannotRead();

  @override
  String toString() => 'That picture could not be read on this phone. '
      'One from the camera roll works.';
}
