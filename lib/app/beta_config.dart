abstract final class BetaConfig {
  static const appName = 'CoLabRoom';
  static const appVersion = '0.3.0';
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
