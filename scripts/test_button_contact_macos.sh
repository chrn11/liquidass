#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'REFUSING: C/Objective-C++/Metal tests are macOS-only' >&2
  exit 2
fi
command -v xcrun >/dev/null || { echo 'missing xcrun' >&2; exit 2; }
command -v clang >/dev/null || { echo 'missing clang' >&2; exit 2; }
python3 "$ROOT/scripts/test_button_contact_source.py"
python3 "$ROOT/scripts/test_local_button_renderer.py"
python3 "$ROOT/scripts/test_button_candidate_integration.py"
python3 "$ROOT/scripts/test_button_optics_source_identity.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RESULTS="${CONTACT_RESULTS:-$ROOT/ci-artifacts/contact-tests}"
mkdir -p "$RESULTS"
python3 "$ROOT/scripts/generate_local_button_shader.py" --msl-out "$RESULTS/contact.metal"
xcrun --sdk macosx metal -c "$RESULTS/contact.metal" -o "$RESULTS/contact.air"
xcrun --sdk macosx metallib -o "$RESULTS/contact.metallib" "$RESULTS/contact.air"
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror -I"$ROOT/Shared" \
  "$ROOT/scripts/test_button_contact_optics.c" -framework CoreGraphics -lm -o "$TMP/contact_cpu"
"$TMP/contact_cpu" | tee "$RESULTS/cpu-contact.log"
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror -I"$ROOT/Shared" \
  "$ROOT/scripts/test_button_material_candidate.c" -framework CoreGraphics -lm -o "$TMP/legacy_optics"
"$TMP/legacy_optics" | tee "$RESULTS/legacy-optics.log"
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror -I"$ROOT/Shared" \
  "$ROOT/scripts/test_local_button_source_contract.c" -framework CoreGraphics -lm -o "$TMP/source_contract"
"$TMP/source_contract" | tee "$RESULTS/source-contract.log"
xcrun --sdk macosx clang++ -std=c++17 -fobjc-arc -fblocks \
  -I"$ROOT/Shared" -I"$ROOT/scripts" \
  "$ROOT/scripts/test_button_contact_metal.mm" \
  -framework Foundation -framework Metal -framework CoreGraphics -o "$TMP/contact_gpu"
set +e
"$TMP/contact_gpu" > "$RESULTS/gpu-contact.log" 2>&1
GPU_RC=$?
set -e
cat "$RESULTS/gpu-contact.log"
if [[ "$GPU_RC" -eq 77 ]]; then
  echo 'NOT_RUN: no Metal device exposed by this macOS runner; no GPU pixel acceptance inferred'
elif [[ "$GPU_RC" -ne 0 ]]; then
  exit "$GPU_RC"
fi
python3 - "$RESULTS" "$GPU_RC" <<'PY'
from pathlib import Path
import json,sys,hashlib
r=Path(sys.argv[1]);code=int(sys.argv[2]);m={'scope':'macOS CI only, NOT iPhone/UI/system-host visual acceptance','cpuNumerical':'PASS','frozenLegacyNoContactNumericRaster':'PASS','MetalOfflineCompiler':'PASS','macOSRealGPU':'PASS' if code==0 else 'NOT_RUN: runner has no Metal device','sourceSHA256':hashlib.sha256((r/'contact.metal').read_bytes()).hexdigest(),'GPUExitCode':code}
(r/'contact-ci-results.json').write_text(json.dumps(m,indent=2));print(json.dumps(m,indent=2))
PY
if [[ -n "${SDK:-}" ]]; then export SDK; fi
sh "$ROOT/scripts/check_local_button_renderer_ios16.sh"
echo 'Source/numeric/Metal compiler checks complete; real GPU is independently recorded, not assumed.'
