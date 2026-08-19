#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/DogearVerify.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

cd "$ROOT"
git diff --check
bash -n scripts/*.sh
scripts/check-sensitive-info.sh
scripts/check-sensitive-info.sh --history
scripts/build.sh --debug --clean \
  --derived-data "$TEMP_ROOT/DebugDerivedData" \
  --output-dir "$TEMP_ROOT/Debug"
scripts/build.sh --release --clean --universal \
  --derived-data "$TEMP_ROOT/ReleaseDerivedData" \
  --output-dir "$TEMP_ROOT/Release"

app="$TEMP_ROOT/Release/Dogear.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")" == "14.0" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$app/Contents/Info.plist")" == "Dogear" ]]

echo "Release verification passed. Live UI, macOS 14 runtime, signing, and notarization remain separate gates."
