#!/usr/bin/env bash
set -euo pipefail

# Creates a locally runnable, ad-hoc signed preview. Developer ID signing and
# Apple notarization are deliberately separate distribution steps.
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="$repo_dir/apps/mobile"
output_dir="${1:-$repo_dir/artifacts}"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'macOS and Xcode are required to package the Mac app.' >&2
  exit 1
fi
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
define_file="$(python3 "$repo_dir/scripts/build_config.py" prepare --platform macos)"
trap 'rm -f "$define_file"' EXIT

cd "$app_dir"
"$repo_dir/scripts/flutter.sh" build macos --release --target lib/main.dart \
  --dart-define-from-file="$define_file"

app="$app_dir/build/macos/Build/Products/Release/Whisplot.app"
[[ -d "$app" ]] || { echo 'Expected release app was not produced.' >&2; exit 1; }
python3 "$repo_dir/scripts/build_config.py" verify --define-file "$define_file" \
  --binary "$app/Contents/Frameworks/App.framework/Versions/A/App"
# Flutter can replace an already signed App.framework during an incremental
# release without refreshing the enclosing app's resource seal. Validate each
# nested framework first; only reseal the outer app, preserving its entitlements.
# Never use --deep signing to silently bless damaged nested code.
for framework in "$app/Contents/Frameworks/"*.framework; do
  codesign --verify --strict "$framework"
done
codesign --force --sign - --preserve-metadata=identifier,entitlements,flags "$app"
codesign --verify --deep --strict "$app"
codesign -d --entitlements - --xml "$app" 2>/dev/null | python3 -c '
import plistlib, sys
entitlements = plistlib.loads(sys.stdin.buffer.read())
if entitlements.get("com.apple.security.get-task-allow", False):
    sys.exit("Release app unexpectedly permits debugger attachment.")
if not entitlements.get("com.apple.security.app-sandbox", False):
    sys.exit("Release app unexpectedly has its sandbox disabled.")
'
if find "$app" -name embedded.provisionprofile -print -quit | grep -q .; then
  echo 'A provisioning profile is embedded; refusing to publish a possibly device-bound preview.' >&2
  exit 1
fi

# Every embedded Mach-O must support an architecture before the archive is
# labelled for it; checking only the small Runner executable is insufficient.
has_arm64=true
has_x86_64=true
binary_count=0
while IFS= read -r -d '' binary; do
  if file -b "$binary" | grep -q 'Mach-O'; then
    archs="$(lipo -archs "$binary")"
    [[ " $archs " == *' arm64 '* ]] || has_arm64=false
    [[ " $archs " == *' x86_64 '* ]] || has_x86_64=false
    binary_count=$((binary_count + 1))
  fi
done < <(find "$app" -type f -print0)
if [[ "$binary_count" -eq 0 ]]; then
  echo 'No native executable found in the app.' >&2
  exit 1
elif $has_arm64 && $has_x86_64; then
  architecture=universal2
elif $has_arm64; then
  architecture=arm64
elif $has_x86_64; then
  architecture=x86_64
else
  echo 'Embedded frameworks do not share a usable architecture.' >&2
  exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
archive="$output_dir/whisplot-$version-macos-$architecture.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
echo "Packaged $binary_count native executables: $architecture"
echo "$archive"
shasum -a 256 "$archive"
