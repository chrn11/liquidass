#!/bin/sh
set -eu
if [ "$(uname -s)" != "Darwin" ]; then
  echo "macOS-only test: refusing non-Darwin compiler/runtime" >&2
  exit 2
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/liquidass-closed-lip.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
clang -std=c11 -Wall -Wextra -Werror -I "$ROOT/Shared" \
  "$ROOT/validation/closed-lip-candidate/test_closed_lip_cpu.c" \
  -lm -o "$TMP/test_closed_lip_cpu"
"$TMP/test_closed_lip_cpu"
