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
}
