#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN_HISTORY=0
[[ "${1:-}" == "--history" ]] && { SCAN_HISTORY=1; shift; }
[[ $# -eq 0 ]] || { echo "Usage: scripts/check-sensitive-info.sh [--history]" >&2; exit 2; }

PATTERN='/Users/|/home/[^/]+/|C:\\Users\\|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|gh[pousr]_[0-9A-Za-z]{20,}|sk-[A-Za-z0-9_-]{16,}|Bearer[[:space:]]+[A-Za-z0-9._~+/-]{16,}'

cd "$PROJECT_ROOT"
matches=()
if [[ "$SCAN_HISTORY" -eq 1 ]]; then
  while IFS= read -r path; do [[ -n "$path" ]] && matches+=("$path"); done < <(
    git rev-list HEAD | while read -r revision; do
      git grep -IlE "$PATTERN" "$revision" -- . ':!scripts/check-sensitive-info.sh' 2>/dev/null || true
    done | sed 's/^[0-9a-f]*://' | sort -u
  )
else
  while IFS= read -r path; do [[ -n "$path" ]] && matches+=("$path"); done < <(
    rg -l --hidden -g '!.git' -g '!.git/**' -g '!scripts/check-sensitive-info.sh' -e "$PATTERN" . || true
  )
fi

if [[ "${#matches[@]}" -gt 0 ]]; then
  echo "error: sensitive or machine-specific patterns were found:" >&2
  printf '  %s\n' "${matches[@]}" >&2
  echo "Values are intentionally omitted; review the files before publication." >&2
  exit 1
fi

if git ls-files | rg -q '(^|/)(xcuserdata|DerivedData|WorkingCopies)(/|$)|\.(p12|pfx|pem|mobileprovision|xcarchive|xcresult|pdf|log)$|(^|/)\.env($|\.)'; then
  echo "error: tracked local, generated, signing, or document artifacts found" >&2
  exit 1
fi

echo "Sensitive-information and tracked-artifact checks passed."
