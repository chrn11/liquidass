#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'REFUSING: C/Objective-C++/Metal tests are macOS-only' >&2
  exit 2
fi
command -v xcrun >/dev/null || { echo 'missing xcrun' >&2; exit 2; }
command -v clang++ >/dev/null || { echo 'missing clang++' >&2; exit 2; }
RESULTS="${MINIFICATION_RESULTS:-$ROOT/ci-artifacts/minification-tests}"
mkdir -p "$RESULTS"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MSL="$RESULTS/minification-candidate.metal"
python3 "$ROOT/scripts/generate_local_button_shader.py" --msl-out "$MSL"
python3 "$ROOT/scripts/test_button_minification_source.py" "$MSL"
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror -I"$ROOT/Shared" \
  "$ROOT/validation/natural-volume-candidate/test_natural_volume_cpu.c" \
  -framework CoreGraphics -lm -o "$TMP/natural-volume-cpu"
"$TMP/natural-volume-cpu" | tee "$RESULTS/natural-volume-cpu.log"
xcrun --sdk macosx metal -c "$MSL" -o "$RESULTS/minification-candidate.air"
xcrun --sdk macosx metallib -o "$RESULTS/minification-candidate.metallib" \
  "$RESULTS/minification-candidate.air"
xcrun --sdk macosx clang++ -std=c++17 -fobjc-arc -fblocks \
  "$ROOT/scripts/test_button_minification_metal.mm" \
  -framework Foundation -framework Metal -framework CoreGraphics \
  -o "$TMP/minification-gpu"
set +e
"$TMP/minification-gpu" "$MSL" >"$RESULTS/minification-gpu.log" 2>&1
GPU_RC=$?
set -e
cat "$RESULTS/minification-gpu.log"
if [[ "$GPU_RC" -ne 0 && "$GPU_RC" -ne 77 ]]; then exit "$GPU_RC"; fi
python3 - "$RESULTS" "$GPU_RC" <<'PY'
from pathlib import Path
import hashlib,json,sys
r=Path(sys.argv[1]);code=int(sys.argv[2]);m={
 'scope':'Mac-only scalar/Metal sample tests; not visual acceptance of the material',
 'sourceMSLSHA256':hashlib.sha256((r/'minification-candidate.metal').read_bytes()).hexdigest(),
 'purePythonStructure':'PASS','CSharedFootprintNumerics':'PASS',
 'MetalOfflineCompiler':'PASS',
 'RealMetalGPUProbe':'PASS' if code==0 else 'NOT_RUN: no Metal device exposed',
 'naturalMaterialVisualAcceptance':'NOT_RUN: parent reviewer must inspect same-input readbacks'}
(r/'minification-test-results.json').write_text(json.dumps(m,indent=2));print(json.dumps(m,indent=2))
PY
echo 'Minification helper validation complete; material visual acceptance remains separate.'
