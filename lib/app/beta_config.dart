abstract final class BetaConfig {
  static const appName = 'CoLabRoom';
  /// Kept in step with pubspec.yaml by hand, and it had drifted three
  /// releases behind — so every crash report, every help request and every
  /// usage row has been labelled 0.3.0 since 0.4.0 shipped. A version that
  /// lies is worse than no version: it points triage at the wrong build.
  static const appVersion = '0.4.1';

  /// Which build this is, as a short commit ref.
  ///
  /// `appVersion` alone cannot answer the question people actually ask, which
  /// is "am I running the thing you just sent me". Every build in a release
  /// says the same number, so an APK that failed to install over its
  /// predecessor is indistinguishable from one that worked -- and on
  /// 2026-09-10 that cost a round trip: a change was reported as missing from
  /// a build that provably contained it, and nothing on screen could settle
  /// it either way.
  ///
  /// Passed by CI as `--dart-define=BUILD_REF=<sha>`. A build made on
  /// somebody's own machine says so rather than claiming a commit it may not
  /// match.
  static const buildRef = String.fromEnvironment(
    'BUILD_REF',
    defaultValue: 'local',
  );

  /// Version and build together, for anywhere a person or a triage query
  /// needs to know exactly what produced something.
  static String get fullVersion => '$appVersion ($buildRef)';
  // These are public client values and are embedded in every mobile/web build. RLS—not
  // secrecy of the publishable key—protects application data.
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://gzcoclsfvazfhcheefhz.supabase.co',
  );
  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'sb_publishable_4f7LPgcNnVyR0STyCSA7FQ_oTymmgvi',
  );
  static const authRedirectUrl = String.fromEnvironment(
    'AUTH_REDIRECT_URL',
    defaultValue: 'com.colabroom.beta://login-callback',
  );

  static bool get hasSupabase =>
      supabaseUrl.trim().isNotEmpty && supabaseAnonKey.trim().isNotEmpty;
}
