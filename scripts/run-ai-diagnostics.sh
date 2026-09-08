#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: bash scripts/run-ai-diagnostics.sh /absolute/path/to/Dogear.app" >&2
  exit 2
fi
app_path="$1"
if [[ "$app_path" != /* || ! -x "$app_path/Contents/MacOS/Dogear" ]]; then
  echo "Expected an absolute path to a built Dogear.app" >&2
  exit 2
fi
"$app_path/Contents/MacOS/Dogear" --run-ai-diagnostics
