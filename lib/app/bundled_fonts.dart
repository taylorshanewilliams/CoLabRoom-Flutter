import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

/// Whether [useBundledFonts] has already run.
///
/// `LicenseRegistry.addLicense` appends, so calling this twice would list the
/// same licence twice on the about page. Tests and the render harness both
/// call it per file, so the guard is not theoretical.
bool _done = false;

/// Draws the app's own type from the app's own assets, never from the network.
///
/// Analyze titles a finished song sheet in Fraunces, and `google_fonts`
/// fetches a face from fonts.gstatic.com the first time it is asked for. That
/// put a network request behind a heading on a screen people open in a
/// rehearsal room with no signal — and it is the screen where the app hands
/// back the chords somebody has just sung, so it is a bad place to fall back
/// to a different typeface.
///
/// With `google_fonts/Fraunces-Medium.ttf` in the asset bundle, google_fonts
/// finds it in the asset manifest and never asks. `allowRuntimeFetching` then
/// makes that a rule rather than a happy accident: with it off, a face that is
/// *not* bundled throws where a developer will see it instead of quietly
/// costing a user a request. Adding a `GoogleFonts.x()` call to this app means
/// adding its file to `google_fonts/` in the same change.
///
/// Called from `main` and from the render harness, which is the other place
/// the app is drawn for real.
void useBundledFonts() {
  if (_done) return;
  _done = true;

  GoogleFonts.config.allowRuntimeFetching = false;

  // Fraunces is under the SIL Open Font License, which asks that the notice
  // travel with the font. Flutter's own licence page is where this app's
  // notices live, so the file beside the font is read into it — the
  // registration google_fonts documents for a bundled face.
  LicenseRegistry.addLicense(() async* {
    final String license =
        await rootBundle.loadString('google_fonts/OFL.txt');
    yield LicenseEntryWithLineBreaks(<String>['google_fonts'], license);
  });
}

/// Puts the flag back, so a test can watch [useBundledFonts] do its work.
@visibleForTesting
void resetBundledFontsForTest() => _done = false;
