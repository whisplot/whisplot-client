#!/usr/bin/env bash
# Package an already-built, unsigned iPhoneOS app. This is NOT installable as-is.
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="$repo_dir/apps/mobile/build/ios/iphoneos/Runner.app"
if [[ ! -d "$app_path" || ! -f "$app_path/Info.plist" ]]; then
  echo 'No iPhoneOS release build found. Run Flutter build ios --release --no-codesign first.' >&2
  exit 1
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Info.plist")"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Info.plist")"
platform="$(/usr/libexec/PlistBuddy -c 'Print :DTPlatformName' "$app_path/Info.plist")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || "$platform" != 'iphoneos' || ! -f "$app_path/$executable" ]]; then
  echo 'Build metadata is not a valid versioned iPhoneOS app.' >&2
  exit 1
fi
if /usr/bin/codesign --display "$app_path" >/dev/null 2>&1; then
  echo 'Refusing to label an already-signed app as unsigned. Rebuild with --no-codesign.' >&2
  exit 1
fi
mkdir -p "$repo_dir/artifacts"
package_dir="$(mktemp -d "${TMPDIR:-/tmp}/hello-mentor-ios-package.XXXXXX")"
trap 'rm -rf "$package_dir"' EXIT
mkdir -p "$package_dir/Payload"
/usr/bin/ditto "$app_path" "$package_dir/Payload/Runner.app"
archive_path="$repo_dir/artifacts/hello-mentor-$version-ios-unsigned.ipa"
staged_archive="$package_dir/release.ipa"
(cd "$package_dir" && /usr/bin/zip -q -r -y "$staged_archive" Payload)
/usr/bin/unzip -tq "$staged_archive"
mv "$staged_archive" "$archive_path"
printf '%s\n' "$archive_path"
printf '%s\n' 'Unsigned development artifact: requires valid Apple signing/provisioning before installation.'
