#!/usr/bin/env bash
# Applies the Gradle fixes required by whisper_ggml / ffmpeg_kit_flutter_new_min
# that a bare `flutter create` scaffold doesn't provide. These were worked out
# and verified against real CI failures in .github/workflows/build-android-debug.yml's
# history; see that file's git log for the failure each patch fixes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_GRADLE="$ROOT/android/app/build.gradle.kts"
ROOT_GRADLE="$ROOT/android/build.gradle.kts"

# whisper_ggml's native module requires a newer side-by-side NDK than the
# one flutter.ndkVersion resolves to on this Flutter version; pin the higher
# version the plugin needs (NDK is backward compatible, so this doesn't
# affect other plugins).
sed -i -E 's/^(\s*)ndkVersion = .*/\1ndkVersion = "29.0.13113456"/' "$APP_GRADLE"

# ffmpeg_kit_flutter_new_min (pulled in transitively by whisper_ggml's
# bundled FFmpeg conversion) requires compiling against API 35+;
# flutter.compileSdkVersion resolves lower on this Flutter version.
sed -i -E 's/^(\s*)compileSdk = .*/\1compileSdk = 36/' "$APP_GRADLE"

grep -q 'ndkVersion = "29.0.13113456"' "$APP_GRADLE" || { echo "::error::ndkVersion patch did not apply"; exit 1; }
grep -q 'compileSdk = 36' "$APP_GRADLE" || { echo "::error::compileSdk patch did not apply"; exit 1; }

# whisper_ggml's own Gradle module (fetched from pub cache, not ours to
# edit) hardcodes compileSdk 34 independently of the app's setting, which
# is too low for its ffmpeg_kit_flutter_new_min dependency. Force every
# plugin subproject's compileSdk from the root build script instead — the
# standard fix for AAR metadata errors caused by a plugin's own compileSdk
# being stuck too low. Skip :app — it's already patched above, and forcing
# afterEvaluate on it here throws "already evaluated" because the
# scaffolded root build.gradle.kts's own
# subprojects { evaluationDependsOn(":app") } block forces :app to
# evaluate early.
{
  echo ''
  echo 'subprojects {'
  echo '    if (project.name != "app") {'
  echo '        afterEvaluate {'
  echo '            extensions.findByType(com.android.build.gradle.BaseExtension::class.java)?.let { android ->'
  echo '                android.compileSdkVersion(36)'
  echo '            }'
  echo '        }'
  echo '    }'
  echo '}'
} >> "$ROOT_GRADLE"

echo "Gradle patches applied."
