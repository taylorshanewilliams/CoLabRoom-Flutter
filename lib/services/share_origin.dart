import 'dart:ui' show FlutterView;

import 'package:flutter/widgets.dart';

/// Where on screen the share sheet was asked for.
///
/// On an iPad the system share sheet is a popover, and UIKit hangs a popover
/// off a rectangle in the window: the control that was tapped. share_plus
/// carries that rectangle as `ShareParams.sharePositionOrigin`, and until
/// this was written not one of the app's seven share calls passed one. Every
/// other platform ignores it, so there is nothing to guard on `kIsWeb` here
/// and nothing that changes on a phone.
///
/// Pass the context of the control itself rather than the screen's. A
/// `Builder` wrapped around the button gives exactly that for nothing: an
/// element with no render object of its own reports the first one below it,
/// which is the button. The screen's context would measure the screen, and a
/// rectangle the size of the whole window is not an anchor -- the popover
/// would have nowhere sensible to point.
///
/// Nobody on this project has an iPad, so this is read off share_plus 13.3.0
/// rather than seen working: FPPSharePlusPlugin.m converts the rectangle into
/// the presenting view's coordinates and, when it comes through empty, falls
/// back to the middle of that view. That is the same fallback [shareOrigin]
/// returns when there is no render box to measure, so the two agree about
/// what an unanchored share looks like instead of disagreeing quietly.
Rect shareOrigin(BuildContext? context) {
  if (context != null && context.mounted) {
    final RenderObject? render = context.findRenderObject();
    if (render is RenderBox &&
        render.attached &&
        render.hasSize &&
        !render.size.isEmpty) {
      // Global, because that is the coordinate space the iOS side converts
      // from. A local rectangle would put the popover at the top of the
      // window however far down the screen the button is.
      return render.localToGlobal(Offset.zero) & render.size;
    }
  }
  return _middleOfTheScreen(context);
}

/// The same answer for a control held by a [GlobalKey] instead of built under
/// a [Builder] -- a control a callback can reach but cannot see.
Rect shareOriginOf(GlobalKey key) => shareOrigin(key.currentContext);

/// A point in the middle of the window, one logical pixel across.
///
/// One pixel rather than nothing: UIKit treats an empty rectangle as no
/// anchor at all, which is the case this whole file exists to stop.
Rect _middleOfTheScreen(BuildContext? context) {
  final FlutterView? view =
      (context != null && context.mounted ? View.maybeOf(context) : null) ??
          WidgetsBinding.instance.platformDispatcher.implicitView;
  if (view == null || view.devicePixelRatio <= 0) {
    // No window to find the middle of, which means no popover either. Still
    // non-empty, so nothing downstream has to treat this as a missing value.
    return const Rect.fromLTWH(0, 0, 1, 1);
  }
  final Size screen = view.physicalSize / view.devicePixelRatio;
  if (screen.isEmpty) return const Rect.fromLTWH(0, 0, 1, 1);
  return Rect.fromCenter(
    center: Offset(screen.width / 2, screen.height / 2),
    width: 1,
    height: 1,
  );
}
