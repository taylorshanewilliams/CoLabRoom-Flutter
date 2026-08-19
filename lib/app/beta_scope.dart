import 'package:flutter/widgets.dart';

import 'music_beta_controller.dart';

class BetaScope extends InheritedNotifier<MusicBetaController> {
  const BetaScope({
    required MusicBetaController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static MusicBetaController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<BetaScope>();
    assert(scope != null, 'BetaScope was not found above this context.');
    return scope!.notifier!;
  }
}
