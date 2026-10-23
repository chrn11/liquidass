#!/bin/sh
set -u

usage() {
  echo "usage: $0 <stage-root> [outDir]" >&2
  echo "<stage-root> must contain Shared/LGCAClosedProfileRuntime.h and Shared/LGCAClosedProfileShaderSource.h" >&2
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=${1:-"$script_dir/../liquidass-ca-closed-main/stage"}
out_root=${2:-"$script_dir/out"}
if [ ! -d "$repo_root" ]; then echo "stage root does not exist: $repo_root" >&2; usage; exit 2; fi
repo_root=$(CDPATH= cd -- "$repo_root" && pwd)
for f in Shared/LGCAClosedProfileRuntime.h Shared/LGCAClosedProfileShaderSource.h; do
  if [ ! -f "$repo_root/$f" ]; then echo "required file missing: $repo_root/$f" >&2; exit 2; fi
done
if ! command -v xcrun >/dev/null 2>&1; then echo "xcrun is required; run this harness on macOS" >&2; exit 2; fi
mkdir -p "$out_root" || exit 2
out_root=$(CDPATH= cd -- "$out_root" && pwd)
sdk=$(xcrun --sdk macosx --show-sdk-path) || exit 2
binary="$out_root/CAClosedRegression"

# This is intentionally the real profile build: no macro-OFF or synthetic
# fallback library is compiled. The baseline is a separate pipeline built from
# the exact kLGCAClosedBaselineMSL bytes embedded in the staged shader header.
xcrun --sdk macosx clang++ \
  -std=c++17 -fobjc-arc -fblocks \
  -DLG_CA_CLOSED_PROFILE_COMPILED=1 \
  -isysroot "$sdk" \
  -I "$repo_root/Shared" \
  "$script_dir/CAClosedRegression.mm" \
  -framework Foundation -framework Metal -framework CoreGraphics -framework ImageIO -framework IOSurface \
  -o "$binary"
compile_status=$?
if [ "$compile_status" -ne 0 ]; then echo "harness build failed ($compile_status)" >&2; exit "$compile_status"; fi

"$binary" "$out_root" "$repo_root/validation/ca-closed-profile/assets/botanical132.bgra"
run_status=$?
case "$run_status" in
  0)  echo "CA-closed Metal regression PASS; report: $out_root/json/run.json" ;;
  1)  echo "CA-closed Metal regression FAIL; inspect: $out_root/json/run.json" >&2 ;;
  77) echo "CA-closed Metal regression NOT_RUN (no Metal device); report: $out_root/json/run.json" >&2 ;;
  *)  echo "CA-closed Metal regression exited $run_status; inspect: $out_root/json/run.json" >&2 ;;
esac
exit "$run_status"
