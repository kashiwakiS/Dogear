#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"

[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.[0-9]+\.[0-9]+$ ]] || {
  echo "Usage: scripts/mark-release-candidate.sh SEMVER" >&2
  exit 2
}

cd "$ROOT"
[[ -z "$(git status --porcelain)" ]] || {
  echo "error: commit all reviewed changes before marking a release candidate" >&2
  exit 1
}
project_version="$(awk '/MARKETING_VERSION =/{gsub(/;/, "", $3); print $3; exit}' PDFWorkBench.xcodeproj/project.pbxproj)"
[[ "$project_version" == "$VERSION" ]] || {
  echo "error: project version is $project_version, not $VERSION" >&2
  exit 1
}

source_branch="$(awk -F= '/source_branch=/{print $2}' .release-source)"
source_commit="$(awk -F= '/source_commit=/{print $2}' .release-source)"
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || { echo "error: invalid integration source commit" >&2; exit 1; }

metadata="$ROOT/.release-source.tmp"
{
  printf 'source_branch=%s\n' "$source_branch"
  printf 'source_commit=%s\n' "$source_commit"
  printf 'status=release-candidate-v%s\n' "$VERSION"
} > "$metadata"
mv "$metadata" "$ROOT/.release-source"

echo "Marked Dogear v$VERSION as a release candidate."
echo "Commit this metadata change, rerun scripts/verify-release.sh, complete live UI/signing gates, then create annotated tag v$VERSION."
