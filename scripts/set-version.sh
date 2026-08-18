#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
BUILD="${2:-}"

[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
  echo "Usage: scripts/set-version.sh SEMVER POSITIVE_BUILD_NUMBER" >&2
  exit 2
}
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || {
  echo "Usage: scripts/set-version.sh SEMVER POSITIVE_BUILD_NUMBER" >&2
  exit 2
}

project="$PROJECT_ROOT/PDFWorkBench.xcodeproj/project.pbxproj"
perl -0pi -e "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/g; s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $BUILD;/g" "$project"

grep -q "MARKETING_VERSION = $VERSION;" "$project"
grep -q "CURRENT_PROJECT_VERSION = $BUILD;" "$project"
echo "Set Dogear version $VERSION ($BUILD)"
