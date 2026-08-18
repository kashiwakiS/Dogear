#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
OUTPUT_ROOT="${2:-$(cd "$ROOT/.." && pwd)/Dogear-Releases}"

[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
  echo "Usage: scripts/package-candidate.sh SEMVER [OUTPUT_ROOT]" >&2
  exit 2
}

cd "$ROOT"
[[ -z "$(git status --porcelain)" ]] || { echo "error: commit all changes before packaging" >&2; exit 1; }
project_version="$(awk '/MARKETING_VERSION =/{gsub(/;/, "", $3); print $3; exit}' PDFWorkBench.xcodeproj/project.pbxproj)"
[[ "$project_version" == "$VERSION" ]] || { echo "error: project version is $project_version, not $VERSION" >&2; exit 1; }

destination="$OUTPUT_ROOT/v$VERSION-candidate"
[[ ! -e "$destination" ]] || { echo "error: destination already exists: $destination" >&2; exit 1; }
temporary="$(mktemp -d "${TMPDIR:-/tmp}/DogearPackage.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT

scripts/verify-release.sh
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
Dogear $VERSION release candidate
Public commit: $(git rev-parse HEAD)
Integration source: $(awk -F= '/source_commit=/{print $2}' .release-source)
Architectures: $(lipo -archs "$temporary/DerivedData/Build/Products/Release/Dogear.app/Contents/MacOS/Dogear")
Signing: unsigned candidate
Notarization: not performed

Do not publish this archive. The tag workflow must create a Developer ID
signed, notarized, and stapled archive.
EOF

echo "Created non-publishable candidate: $destination"
