#!/bin/zsh
# Sets the version of every pet: VERSION (read by the Mac build scripts) and windows/package.json.
#   Tools/set-version.sh 1.5.0
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 1 ]] || { echo "usage: Tools/set-version.sh <x.y.z>"; exit 1; }
echo "$1" > VERSION
python3 - "$1" <<'PY'
import json, sys
f = "windows/package.json"
d = json.load(open(f, encoding="utf-8"))
d["version"] = sys.argv[1]
open(f, "w", encoding="utf-8").write(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
PY
echo "version $1"
