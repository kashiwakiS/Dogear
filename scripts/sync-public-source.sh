#!/usr/bin/env bash
set -euo pipefail

PUBLIC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_WORKTREE="${1:-}"
SOURCE_REF="${2:-release/phase-1-mvp}"

usage() {
  cat <<'USAGE'
Usage: scripts/sync-public-source.sh SOURCE_WORKTREE [SOURCE_REF]

Copy only committed application source from an integration worktree into this
public-release worktree. Public README, licensing, CI, packaging, and release
scripts are preserved. The source commit is recorded in .release-source.
USAGE
}

[[ -n "$SOURCE_WORKTREE" ]] || { usage >&2; exit 2; }
git -C "$SOURCE_WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "error: not a Git worktree: $SOURCE_WORKTREE" >&2
  exit 2
}

cd "$PUBLIC_ROOT"
branch="$(git branch --show-current)"
[[ "$branch" == codex/dogear-public-* || "$branch" == release/dogear-* ]] || {
  echo "error: refusing to sync outside a Dogear public-release branch" >&2
  exit 1
}
[[ -z "$(git status --porcelain)" ]] || {
  echo "error: public worktree is not clean; commit or discard its changes first" >&2
  exit 1
}

source_commit="$(git -C "$SOURCE_WORKTREE" rev-parse "$SOURCE_REF^{commit}")"
version="$(awk '/MARKETING_VERSION =/{gsub(/;/, "", $3); print $3; exit}' PDFWorkBench.xcodeproj/project.pbxproj)"
build="$(awk '/CURRENT_PROJECT_VERSION =/{gsub(/;/, "", $3); print $3; exit}' PDFWorkBench.xcodeproj/project.pbxproj)"
staging="$(mktemp -d "${TMPDIR:-/tmp}/DogearPublicSync.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

git -C "$SOURCE_WORKTREE" archive "$source_commit" -- \
  Branding/AppIcon/Dogear-AppIcon-Source.png \
  Config \
  PDFWorkBench \
  PDFWorkBench.xcodeproj/project.pbxproj \
  PDFWorkBench.xcodeproj/project.xcworkspace/contents.xcworkspacedata \
  PDFWorkBench.xcodeproj/xcshareddata/xcschemes/PDFWorkBench.xcscheme \
  | tar -x -C "$staging"

rsync -a --delete "$staging/Branding/" "$PUBLIC_ROOT/Branding/"
rsync -a --delete "$staging/Config/" "$PUBLIC_ROOT/Config/"
rsync -a --delete "$staging/PDFWorkBench/" "$PUBLIC_ROOT/PDFWorkBench/"
rsync -a --delete "$staging/PDFWorkBench.xcodeproj/" "$PUBLIC_ROOT/PDFWorkBench.xcodeproj/"

# Shared schemes must never run maintainer-local build side effects.
scheme="$PUBLIC_ROOT/PDFWorkBench.xcodeproj/xcshareddata/xcschemes/PDFWorkBench.xcscheme"
perl -0pi -e 's{\s*<PostActions>.*?</PostActions>}{}s' "$scheme"

# Remove Xcode's machine/user attribution header from the public snapshot.
while IFS= read -r -d '' swift_file; do
  perl -ni -e 'print unless m{^\s*//\s+Created by .+ on .+\.\s*$}' "$swift_file"
done < <(find "$PUBLIC_ROOT/PDFWorkBench" -type f -name '*.swift' -print0)

"$PUBLIC_ROOT/scripts/set-version.sh" "$version" "$build"
metadata="$PUBLIC_ROOT/.release-source.tmp"
{
  printf 'source_branch=%s\n' "$SOURCE_REF"
  printf 'source_commit=%s\n' "$source_commit"
  printf 'status=development-snapshot-do-not-publish\n'
} > "$metadata"
mv "$metadata" "$PUBLIC_ROOT/.release-source"

"$PUBLIC_ROOT/scripts/check-sensitive-info.sh"
echo "Synced committed source $SOURCE_REF at $source_commit"
echo "Review the diff, build, test, and commit this public snapshot."
