abstract final class BetaConfig {
  static const appName = 'CoLabRoom';
  /// Kept in step with pubspec.yaml by hand, and it had drifted three
  /// releases behind — so every crash report, every help request and every
  /// usage row has been labelled 0.3.0 since 0.4.0 shipped. A version that
  /// lies is worse than no version: it points triage at the wrong build.
  static const appVersion = '0.4.0';
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
