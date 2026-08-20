#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
OUTPUT_ROOT="${2:-$(cd "$ROOT/.." && pwd)/Dogear-Releases}"

[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.[0-9]+\.[0-9]+$ ]] || {
  echo "Usage: scripts/package-release.sh SEMVER [OUTPUT_ROOT]" >&2
  exit 2
}

cd "$ROOT"
[[ -z "$(git status --porcelain)" ]] || {
  echo "error: commit all release changes before packaging" >&2
  exit 1
}

project_version="$(awk '/MARKETING_VERSION =/{gsub(/;/, "", $3); print $3; exit}' PDFWorkBench.xcodeproj/project.pbxproj)"
[[ "$project_version" == "$VERSION" ]] || {
  echo "error: project version is $project_version, not $VERSION" >&2
  exit 1
}

source_status="$(awk -F= '/status=/{print $2}' .release-source)"
[[ "$source_status" == "release-candidate-v$VERSION" ]] || {
  echo "error: .release-source must be release-candidate-v$VERSION, got $source_status" >&2
  exit 1
}

release_notes="$ROOT/RELEASE-NOTES.md"
[[ -s "$release_notes" ]] || {
  echo "error: add RELEASE-NOTES.md before packaging" >&2
  exit 1
}
grep -q "^# Dogear $VERSION$" "$release_notes" || {
  echo "error: RELEASE-NOTES.md must start with '# Dogear $VERSION'" >&2
  exit 1
}

scripts/check-sensitive-info.sh
scripts/check-sensitive-info.sh --history

identity="${DOGEAR_SIGNING_IDENTITY:-}"
identity_listing="$(security find-identity -v -p codesigning)"
if [[ -z "$identity" ]]; then
  identity_count="$(printf '%s\n' "$identity_listing" | awk -F'"' '/"Developer ID Application:/{count++} END {print count + 0}')"
  [[ "$identity_count" -eq 1 ]] || {
    echo "error: expected exactly one Developer ID Application identity, found $identity_count" >&2
    echo "Set DOGEAR_SIGNING_IDENTITY to choose an installed identity explicitly." >&2
    exit 1
  }
  identity="$(printf '%s\n' "$identity_listing" | awk -F'"' '/"Developer ID Application:/{print $2; exit}')"
fi

[[ "$identity" == "Developer ID Application: "* ]] || {
  echo "error: official packages require a Developer ID Application identity" >&2
  exit 1
}
printf '%s\n' "$identity_listing" | grep -Fq "\"$identity\"" || {
  echo "error: signing identity is not available in the current keychain: $identity" >&2
  exit 1
}

destination="$OUTPUT_ROOT/v$VERSION"
[[ ! -e "$destination" ]] || {
  echo "error: destination already exists: $destination" >&2
  exit 1
}

temporary="$(mktemp -d "${TMPDIR:-/tmp}/DogearRelease.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT

scripts/build.sh --release --clean --universal \
  --derived-data "$temporary/DerivedData" \
  --output-dir "$temporary/App"
app="$temporary/App/Dogear.app"
codesign --force \
  --options runtime \
  --timestamp \
  --entitlements "$ROOT/PDFWorkBench/PDFWorkBench.entitlements" \
  --sign "$identity" \
  "$app"
codesign --verify --deep --strict --verbose=2 "$app"

mkdir -p "$destination"

app_archive="Dogear-$VERSION-macOS-universal.zip"
source_archive="Dogear-$VERSION-source.zip"
ditto -c -k --sequesterRsrc --keepParent \
  "$app" \
  "$destination/$app_archive"
git archive --format=zip --prefix="Dogear-$VERSION/" -o "$destination/$source_archive" HEAD
install -m 0644 "$release_notes" "$destination/RELEASE-NOTES.md"

archive_check="$temporary/ArchiveCheck"
mkdir -p "$archive_check"
ditto -x -k "$destination/$app_archive" "$archive_check"
archived_app="$archive_check/Dogear.app"
codesign --verify --deep --strict --verbose=2 "$archived_app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$archived_app/Contents/Info.plist")" == "$VERSION" ]] || {
  echo "error: archived app version does not match $VERSION" >&2
  exit 1
}
archived_architectures="$(lipo -archs "$archived_app/Contents/MacOS/Dogear")"
[[ "$archived_architectures" == "x86_64 arm64" || "$archived_architectures" == "arm64 x86_64" ]] || {
  echo "error: archived app is not universal: $archived_architectures" >&2
  exit 1
}

(
  cd "$destination"
  shasum -a 256 "$app_archive" "$source_archive" > SHA256SUMS
)

cat > "$destination/RELEASE-MANIFEST.txt" <<EOF
Dogear $VERSION
Public commit: $(git rev-parse HEAD)
Integration source: $(awk -F= '/source_commit=/{print $2}' .release-source)
Architectures: $archived_architectures
Release notes: RELEASE-NOTES.md
Signing: Developer ID Application (verified after archiving)
Notarization: not performed
EOF

echo "Created release assets: $destination"
