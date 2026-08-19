#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="Debug"
DERIVED_DATA_PATH="${DOGEAR_DERIVED_DATA:-$PROJECT_ROOT/build/DerivedData}"
OUTPUT_DIR="${DOGEAR_OUTPUT_DIR:-$PROJECT_ROOT/build/$CONFIGURATION}"
CLEAN=0
UNIVERSAL=0

usage() {
  cat <<'USAGE'
Usage: scripts/build.sh [--debug|--release] [--clean] [--universal]
                        [--derived-data PATH] [--output-dir PATH]

Build Dogear without requiring a signing identity. --universal builds arm64
and x86_64 slices and is intended for release candidates. The final app is
written to build/<Configuration>/Dogear.app by default. --output-dir changes
that final app directory; --derived-data changes only Xcode's intermediates.
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
    --output-dir)
      [[ $# -ge 2 ]] || { echo "error: --output-dir requires a path" >&2; exit 2; }
      OUTPUT_DIR="$2"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ -z "${DEVELOPER_DIR:-}" ]] && [[ "$(xcode-select -p 2>/dev/null || true)" != *.app/Contents/Developer ]]; then
  for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app /Applications/Xcode_*.app; do
    if [[ -x "$candidate/Contents/Developer/usr/bin/xcodebuild" ]]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      break
    fi
  done
fi

command -v xcodebuild >/dev/null || {
  echo "error: xcodebuild is required" >&2
  exit 1
}
xcodebuild -version >/dev/null 2>&1 || {
  echo "error: select a full Xcode with xcode-select or set DEVELOPER_DIR" >&2
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

built_app="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/Dogear.app"
built_executable="$built_app/Contents/MacOS/Dogear"
[[ -x "$built_executable" ]] || { echo "error: missing app executable: $built_executable" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"
app="$OUTPUT_DIR/Dogear.app"
rm -rf "$app"
ditto "$built_app" "$app"
executable="$app/Contents/MacOS/Dogear"

minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
architectures="$(lipo -archs "$executable")"
printf 'Built %s (version %s, macOS %s+, %s)\n' "$app" "$version" "$minimum" "$architectures"
