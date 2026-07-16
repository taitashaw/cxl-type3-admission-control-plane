#!/usr/bin/env bash
# make_manifest.sh — SHA-256 every material evidence + source file into
# evidence/manifest.json so each numerical claim is anchored to a hashed artifact.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
OUT=evidence/manifest.json
{
  echo "{"
  echo "  \"project\": \"project2_cxl_validation\","
  echo "  \"note\": \"SHA-256 of evidence and hardened-M1 sources. No machine-specific paths.\","
  echo "  \"files\": ["
  first=1
  while IFS= read -r f; do
    h=$(sha256sum "$f" | cut -d' ' -f1)
    [ $first -eq 0 ] && echo ","
    first=0
    printf '    {"path": "%s", "sha256": "%s"}' "$f" "$h"
  done < <(find evidence/raw rtl tb/models tb/sv scripts -type f \( -name '*.log' -o -name '*.sv' -o -name '*.py' -o -name '*.sh' \) | sort)
  echo ""
  echo "  ]"
  echo "}"
} > "$OUT"
echo "wrote $OUT ($(grep -c sha256 "$OUT") files hashed)"
