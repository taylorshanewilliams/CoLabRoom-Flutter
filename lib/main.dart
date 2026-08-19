import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/beta_config.dart';
import 'app/colabroom_app.dart';
import 'app/colabroom_theme.dart';
import 'app/music_beta_controller.dart';
import 'data/in_memory_music_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ErrorWidget.builder = (_) {
    return const ColoredBox(
      color: AppColors.ink,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.sync_problem_rounded, color: AppColors.cyan, size: 42),
                SizedBox(height: 14),
                Text(
                  'CoLabRoom hit a problem.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 7),
                Text(
                  'Close and reopen the app. Your saved Rooms are still secure.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.muted, height: 1.4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  };

  if (BetaConfig.hasSupabase) {
    await Supabase.initialize(
      url: BetaConfig.supabaseUrl,
      publishableKey: BetaConfig.supabaseAnonKey,
    );
    runApp(CoLabRoomApp.supabase(client: Supabase.instance.client));
  } else {
    final controller = MusicBetaController(InMemoryMusicRepository.seeded());
    await controller.load();
    runApp(CoLabRoomApp.preview(controller: controller));
  }
}
