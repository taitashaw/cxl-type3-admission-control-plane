#!/usr/bin/env bash
# bootstrap_formal.sh — fetch a pinned OSS CAD Suite (Yosys + SymbiYosys +
# solvers) into tools/ WITHOUT root. Verifies the archive hash before extract.
# No unaudited pipe-to-shell; the archive is downloaded to disk, hashed, then
# extracted. Re-running is idempotent.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
mkdir -p tools

# Pinned release (OSS CAD Suite, linux-x64). Update deliberately, not silently.
REL="2026-07-16"
URL="https://github.com/YosysHQ/oss-cad-suite-build/releases/download/${REL}/oss-cad-suite-linux-x64-${REL//-/}.tgz"
TGZ="tools/oss-cad-suite.tgz"
# Recorded SHA-256 of the pinned archive (verify on first fetch).
EXPECT_SHA="3e041570d0bd4c94c4fa56dd148c27e959f3992c8251038bcfa8913af4c09703"

if [ -f tools/oss-cad-suite/environment ]; then
  echo "OSS CAD Suite already present at tools/oss-cad-suite"; exit 0
fi
if [ ! -f "$TGZ" ]; then
  echo "downloading pinned OSS CAD Suite $REL ..."
  curl -fsSL "$URL" -o "$TGZ"
fi
GOT_SHA=$(sha256sum "$TGZ" | cut -d' ' -f1)
if [ "$GOT_SHA" != "$EXPECT_SHA" ]; then
  echo "CHECKSUM MISMATCH: got $GOT_SHA expected $EXPECT_SHA" >&2
  echo "refusing to extract an unverified archive." >&2
  exit 1
fi
echo "checksum OK ($GOT_SHA); extracting ..."
tar -xzf "$TGZ" -C tools/
source tools/oss-cad-suite/environment
echo "installed: $(yosys --version | head -1)"
echo "run: make formal"
