#!/usr/bin/env bash
set -euo pipefail

[[ $# -ge 3 && $# -le 4 ]] || {
  echo "Usage: scripts/prepare-release.sh SOURCE_WORKTREE VERSION BUILD [SOURCE_REF]" >&2
  exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_WORKTREE="$1"
VERSION="$2"
BUILD="$3"
SOURCE_REF="${4:-release/phase-1-mvp}"

"$ROOT/scripts/sync-public-source.sh" "$SOURCE_WORKTREE" "$SOURCE_REF"
"$ROOT/scripts/set-version.sh" "$VERSION" "$BUILD"
"$ROOT/scripts/check-sensitive-info.sh"

echo
echo "Prepared an uncommitted Dogear $VERSION ($BUILD) snapshot."
echo "Next: review the diff, commit it, run scripts/verify-release.sh, then tag only the verified commit."
