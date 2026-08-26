import 'package:flutter/widgets.dart';

import 'music_beta_controller.dart';

class BetaScope extends InheritedNotifier<MusicBetaController> {
  const BetaScope({
    required MusicBetaController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  /// The controller, rebuilding this widget whenever it changes.
  ///
  /// Pass `listen: false` from a callback or a lifecycle method. A tap handler
  /// that only wants to call a method has no business subscribing its widget
  /// to every future change, and outside of build there is nothing to
  /// subscribe to in the first place.
  static MusicBetaController of(BuildContext context, {bool listen = true}) {
    final scope = listen
        ? context.dependOnInheritedWidgetOfExactType<BetaScope>()
        : context.getInheritedWidgetOfExactType<BetaScope>();
    assert(scope != null, 'BetaScope was not found above this context.');
    return scope!.notifier!;
  }

  /// The controller if there is one, and null if there is not.
  ///
  /// For decoration that a screen can do without: a member's colour, a face.
  /// [of] asserts, which is right for a screen that cannot function without a
  /// controller and wrong for a screen that is pumped in a widget test with
  /// nothing above it — the tests that exist precisely so a screen can be
  /// built without a live Supabase behind it. Something optional should be
  /// asked for optionally rather than making the whole screen untestable.
  static MusicBetaController? maybeOf(BuildContext context,
      {bool listen = true}) {
    final scope = listen
        ? context.dependOnInheritedWidgetOfExactType<BetaScope>()
        : context.getInheritedWidgetOfExactType<BetaScope>();
    return scope?.notifier;
  }
}
