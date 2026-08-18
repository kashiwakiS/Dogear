#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="Debug"
DERIVED_DATA_PATH="${DOGEAR_DERIVED_DATA:-${TMPDIR:-/tmp}/DogearDerivedData}"
CLEAN=0
UNIVERSAL=0

usage() {
  cat <<'USAGE'
Usage: scripts/build.sh [--debug|--release] [--clean] [--universal]
                        [--derived-data PATH]

Build Dogear without requiring a signing identity. --universal builds arm64
and x86_64 slices and is intended for release candidates.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) CONFIGURATION="Debug" ;;
    --release) CONFIGURATION="Release" ;;
    --clean) CLEAN=1 ;;
    --universal) UNIVERSAL=1 ;;
    --derived-data)
      [[ $# -ge 2 ]] || { echo "error: --derived-data requires a path" >&2; exit 2; }
      DERIVED_DATA_PATH="$2"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

command -v xcodebuild >/dev/null || {
  echo "error: xcodebuild is required" >&2
  exit 1
}

arguments=(
  -project "$PROJECT_ROOT/PDFWorkBench.xcodeproj"
  -scheme PDFWorkBench
  -configuration "$CONFIGURATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
)

if [[ "$UNIVERSAL" -eq 1 ]]; then
  arguments+=(ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO)
fi

if [[ "$CLEAN" -eq 1 ]]; then
  xcodebuild "${arguments[@]}" clean
fi
xcodebuild "${arguments[@]}" build

app="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/Dogear.app"
executable="$app/Contents/MacOS/Dogear"
[[ -x "$executable" ]] || { echo "error: missing app executable: $executable" >&2; exit 1; }

minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
architectures="$(lipo -archs "$executable")"
printf 'Built %s (version %s, macOS %s+, %s)\n' "$app" "$version" "$minimum" "$architectures"
