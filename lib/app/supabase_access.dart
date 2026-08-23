import 'package:supabase_flutter/supabase_flutter.dart';

/// The signed-in user's id, or null when there is no Supabase to ask.
///
/// `Supabase.instance` asserts that initialization has happened, so reading
/// it from a widget's `build` throws outright in the preview/test
/// configuration — which is the whole point of `CoLabRoomApp.preview`. The
/// screens that call this are perfectly capable of rendering without knowing
/// who the user is (they fall back to a default author colour), so an
/// unconfigured backend should degrade rather than crash the frame.
String? currentUserIdOrNull() {
  try {
    return Supabase.instance.client.auth.currentUser?.id;
  } catch (_) {
    return null;
  }
}
