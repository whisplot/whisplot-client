#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -x "$repo_dir/.tooling/flutter/bin/flutter" ]]; then
  exec "$repo_dir/.tooling/flutter/bin/flutter" "$@"
elif command -v flutter >/dev/null 2>&1; then
  exec flutter "$@"
else
  echo 'Flutter SDK not found. Install stable Flutter: https://docs.flutter.dev/install' >&2
  exit 1
fi
