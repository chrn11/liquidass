#!/bin/sh
set -eu
if [ "$(uname -s)" != "Darwin" ]; then
  echo "macOS-only test: refusing non-Darwin compiler/runtime" >&2
  exit 2
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/liquidass-edge-radiance.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
clang -std=c11 -Wall -Wextra -Werror -I "$ROOT/Shared" \
  "$ROOT/validation/edge-radiance-candidate/test_edge_radiance_cpu.c" \
  -lm -o "$TMP/test_edge_radiance_cpu"
"$TMP/test_edge_radiance_cpu"
