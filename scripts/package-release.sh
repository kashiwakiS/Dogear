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

scripts/check-sensitive-info.sh
scripts/check-sensitive-info.sh --history

destination="$OUTPUT_ROOT/v$VERSION"
[[ ! -e "$destination" ]] || {
  echo "error: destination already exists: $destination" >&2
  exit 1
}

temporary="$(mktemp -d "${TMPDIR:-/tmp}/DogearRelease.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT

scripts/build.sh --release --clean --universal --derived-data "$temporary/DerivedData"
mkdir -p "$destination"

app_archive="Dogear-$VERSION-macOS-universal-UNSIGNED.zip"
source_archive="Dogear-$VERSION-source.zip"
ditto -c -k --sequesterRsrc --keepParent \
  "$temporary/DerivedData/Build/Products/Release/Dogear.app" \
  "$destination/$app_archive"
git archive --format=zip --prefix="Dogear-$VERSION/" -o "$destination/$source_archive" HEAD

(
  cd "$destination"
  shasum -a 256 "$app_archive" "$source_archive" > SHA256SUMS
)

cat > "$destination/RELEASE-MANIFEST.txt" <<EOF
Dogear $VERSION
Public commit: $(git rev-parse HEAD)
Integration source: $(awk -F= '/source_commit=/{print $2}' .release-source)
Architectures: $(lipo -archs "$temporary/DerivedData/Build/Products/Release/Dogear.app/Contents/MacOS/Dogear")
Signing: not performed
Notarization: not performed
EOF

echo "Created release assets: $destination"
