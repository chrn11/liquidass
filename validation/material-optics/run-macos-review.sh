#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS/Xcode required; no Linux compile fallback'; exit 2; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
V="$ROOT/validation/material-optics"
OUT="$ROOT/ci-artifacts/material-optics-review"
mkdir -p "$OUT"
exec > >(tee "$OUT/review-build.log") 2>&1
python3 - "$ROOT" "$V" <<'PY'
import sys,json,hashlib
from pathlib import Path
root=Path(sys.argv[1]);v=Path(sys.argv[2]);m=json.loads((v/'review-input-manifest.json').read_text())
assert sys.platform=='darwin'
for n,h in m['fixedInputSHA256'].items():assert hashlib.sha256((v/n).read_bytes()).hexdigest()==h,n
assert hashlib.sha256((v/'baseline.metal').read_bytes()).hexdigest()==m['baselineMSLSHA256']
assert hashlib.sha256((v/'candidate.metal').read_bytes()).hexdigest()==m['candidateMSLSHA256']
print('All isolated same-input reviewer bytes pinned; baseline product source not replaced.')
PY
xcrun --sdk macosx clang --version
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror \
  "$V/candidate-source/validation/natural-volume-candidate/test_natural_volume_cpu.c" \
  -lm -o "$OUT/natural-volume-cpu"
"$OUT/natural-volume-cpu"
for SHADER in baseline candidate; do
  xcrun --sdk macosx metal -c "$V/$SHADER.metal" -o "$OUT/$SHADER.air"
  xcrun --sdk macosx metallib "$OUT/$SHADER.air" -o "$OUT/$SHADER.metallib"
done
xcrun --sdk macosx clang++ -std=c++17 -fobjc-arc -fblocks -I"$ROOT/Shared" \
  "$V/MaterialABRuntimeReview.mm" -framework Foundation -framework Metal \
  -framework CoreGraphics -framework ImageIO -o "$OUT/MaterialABRuntimeReview"
export BASELINE_METAL="$V/baseline.metal" CANDIDATE_METAL="$V/candidate.metal"
export MATERIAL_INPUTS="$V/inputs" MATERIAL_RESULTS="$OUT"
set +e
"$OUT/MaterialABRuntimeReview"
RC=$?
set -e
cp "$V/review-input-manifest.json" "$OUT/review-input-manifest.json"
python3 - "$OUT" "$RC" <<'PY'
import json,sys,os
from pathlib import Path
out=Path(sys.argv[1]);code=int(sys.argv[2]);status='NOT_RUN_NO_METAL_DEVICE' if code==77 else ('PASS' if code==0 else 'FAIL')
r={'runID':os.environ['GITHUB_RUN_ID'],'commit':os.environ['GITHUB_SHA'],'runner':'macOS Apple Xcode','CPUValueTests':'PASS','MetalOfflineCompiler':'PASS','actualGPU':status,'GPUExitCode':code,'phoneOrSystemRuntime':'NOT_RUN','candidateProductIntegratedOrInstalled':False,'visualAcceptance':'REQUIRES_ACTUAL_IMAGE_REVIEW'}
(out/'ci-provenance.json').write_text(json.dumps(r,indent=2));print(json.dumps(r,indent=2))
PY
if [[ "$RC" == 77 ]]; then exit 0; fi
exit "$RC"
