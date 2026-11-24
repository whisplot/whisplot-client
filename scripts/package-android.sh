#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="$repo_dir/apps/mobile"
output_dir="${1:-$repo_dir/artifacts}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
define_file="$(python3 "$repo_dir/scripts/build_config.py" prepare --platform android)"
trap 'rm -f "$define_file"' EXIT
previous_apk=""
if [[ -n "${HELLO_MENTOR_PREVIOUS_ANDROID_APK:-}" ]]; then
  previous_apk="$(cd "$(dirname "$HELLO_MENTOR_PREVIOUS_ANDROID_APK")" && pwd)/$(basename "$HELLO_MENTOR_PREVIOUS_ANDROID_APK")"
fi

cd "$app_dir"
"$repo_dir/scripts/flutter.sh" build apk --release --target lib/main.dart \
  --target-platform android-arm64 --split-per-abi \
  --dart-define-from-file="$define_file"

python3 "$repo_dir/scripts/validate_android_package.py" \
  --apk "$app_dir/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk" \
  --define-file "$define_file" --output-directory "$output_dir" --previous-apk "$previous_apk"
