#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDK="${SDK:?CI must supply the pinned iPhoneOS16.5.sdk}"
OUT="$ROOT/ci-artifacts/local-renderer-hardening-build30"
C="$ROOT/validation/nativeplay/carrier"
O="$OUT/objects"; APP="$OUT/NativePlayLab.app"
mkdir -p "$O" "$APP" "$OUT/logs"
exec > >(tee "$OUT/logs/build.log") 2>&1
[ "$(uname -s)" = Darwin ] || { echo 'macOS/Xcode runner required; Linux builds prohibited'; exit 1; }
xcrun --sdk iphoneos clang --version
xcrun --sdk iphoneos --find ld
python3 "$ROOT/validation/nativeplay/verify_ci_inputs.py" "$ROOT" "$SDK"
python3 "$ROOT/scripts/generate_local_button_shader.py"
# Host C behavior checks are on macOS, not an iOS executable or a Linux fallback.
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror \
  "$ROOT/scripts/test_local_button_source_contract.c" -framework CoreGraphics -lm -o "$OUT/host-contract-test"
"$OUT/host-contract-test"
# All new numeric/Metal compilation is executed here on macOS only. A runner
# with no Metal device reports GPU NOT_RUN rather than manufacturing PASS.
# Explicit designed-light device experiment: retain source/state/lease guards,
# migrate model-specific tests to the exact previously reviewed closed-lip shader.
# Historical contact raster baselines remain archived, not relabelled as this model.
python3 "$ROOT/scripts/test_button_contact_source.py"
python3 "$ROOT/scripts/test_local_button_renderer.py"
python3 "$ROOT/scripts/test_button_candidate_integration.py"
python3 "$ROOT/validation/nativeplay/verify_designed_light_device.py" "$ROOT"
python3 "$ROOT/validation/nativeplay/guard_touch_and_capture.py" "$ROOT"
LIQUIDASS_TOUCH_BASELINE_ROOT="$ROOT" python3 "$ROOT/validation/nativeplay/test_guard_mutations.py"
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror -I"$ROOT/validation/nativeplay" \
  "$ROOT/validation/nativeplay/test_designed_light_gate_policy.c" -lm -o "$OUT/gate-policy-test"
"$OUT/gate-policy-test"
python3 "$ROOT/validation/nativeplay/check_designed_light_gates_macos.py" "$ROOT" "$OUT/gate-matrix" "$SDK"
bash "$ROOT/validation/nativeplay/run_macos_capture_tests.sh" "$ROOT" "$OUT/capture-hardening-tests"
python3 "$ROOT/scripts/generate_local_button_shader.py" --msl-out "$OUT/designed-light.metal"
xcrun --sdk iphoneos metal -c "$OUT/designed-light.metal" -o "$OUT/designed-light.air"
xcrun --sdk iphoneos metallib "$OUT/designed-light.air" -o "$OUT/designed-light.metallib"
for MODEL_TEST in validation/closed-lip-candidate/test_closed_lip_cpu.c validation/designed-light-candidate/test_designed_light_cpu.c validation/edge-radiance-candidate/test_edge_exterior_cpu.c; do
  TEST_NAME="$(basename "$MODEL_TEST" .c)"
  xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror -I"$ROOT/Shared" "$ROOT/$MODEL_TEST" -framework CoreGraphics -lm -o "$OUT/$TEST_NAME"
  "$OUT/$TEST_NAME"
done
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror -I"$ROOT/Shared" \
  "$ROOT/validation/appowned-source/test_appowned_lease_policy.c" -framework CoreGraphics -lm -o "$OUT/owned-source-policy-test"
"$OUT/owned-source-policy-test"
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror -I"$ROOT/Shared" \
  "$ROOT/scripts/test_settings_back_button_local_state.c" -framework CoreGraphics -lm -o "$OUT/host-state-test"
"$OUT/host-state-test"
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror -I"$ROOT/Shared" \
  "$ROOT/scripts/test_local_refresh_policy.c" -framework CoreGraphics -lm -o "$OUT/local-refresh-policy-test"
"$OUT/local-refresh-policy-test"
python3 "$ROOT/validation/nativeplay/check_actual_hook_macos.py"
CFLAGS=(-target arm64-apple-ios16.5 -isysroot "$SDK" -miphoneos-version-min=16.5 -fobjc-arc -fblocks -O1 -Werror=format -DLG_LOCAL_BUTTON_RENDERER_COMPILED=1 -DLG_LOCAL_DESIGNED_LIGHT_EXPERIMENT=1 -I"$ROOT/Shared" -I"$C" -I"$ROOT/validation/nativeplay")
# Exactly one actual source class and the same existing NativePlayLab carrier.
xcrun --sdk iphoneos clang "${CFLAGS[@]}" -c "$C/NativePlayLabViewController.m" -o "$O/NativePlayLabViewController.o"
xcrun --sdk iphoneos clang "${CFLAGS[@]}" -c "$C/main.m" -o "$O/main.o"
xcrun --sdk iphoneos clang++ "${CFLAGS[@]}" -std=c++17 -c "$ROOT/validation/nativeplay/LocalRendererRuntimeProbe.mm" -o "$O/LocalRendererRuntimeProbe.o"
xcrun --sdk iphoneos clang++ "${CFLAGS[@]}" -std=c++17 -c "$ROOT/Shared/LGLocalButtonMaterialView.mm" -o "$O/LGLocalButtonMaterialView.o"
xcrun --sdk iphoneos clang++ "${CFLAGS[@]}" -std=c++17 -c "$ROOT/Shared/LGAppOwnedButtonSourceProvider.mm" -o "$O/LGAppOwnedButtonSourceProvider.o"
xcrun --sdk iphoneos clang++ "${CFLAGS[@]}" -std=c++17 -c "$ROOT/validation/nativeplay/AppOwnedBackgroundRuntimeProbe.mm" -o "$O/AppOwnedBackgroundRuntimeProbe.o"
xcrun --sdk iphoneos clang++ "${CFLAGS[@]}" -std=c++17 -Werror=objc-method-access -c "$ROOT/validation/nativeplay/OwnedTouchRuntimeProbe.mm" -o "$O/OwnedTouchRuntimeProbe.o"
xcrun --sdk iphoneos clang++ -target arm64-apple-ios16.5 -isysroot "$SDK" \
  -miphoneos-version-min=16.5 -Wl,-no_adhoc_codesign -o "$APP/NativePlayLab" \
  "$O/main.o" "$O/NativePlayLabViewController.o" "$O/LocalRendererRuntimeProbe.o" "$O/LGLocalButtonMaterialView.o" "$O/LGAppOwnedButtonSourceProvider.o" "$O/AppOwnedBackgroundRuntimeProbe.o" "$O/OwnedTouchRuntimeProbe.o" \
  -framework UIKit -framework Metal -framework MetalKit -framework QuartzCore \
  -framework CoreGraphics -framework ImageIO -framework Foundation -lobjc -lc++
# No codesign/ldid, installation, release publication, device preferences or restart.
python3 "$ROOT/validation/nativeplay/package_ci_app.py" "$ROOT" "$OUT" "$SDK"
xcrun lipo -info "$APP/NativePlayLab" | tee "$OUT/logs/actual-architecture.log"
xcrun otool -l "$APP/NativePlayLab" > "$OUT/logs/load-commands.txt"
if rg -q 'LC_CODE_SIGNATURE' "$OUT/logs/load-commands.txt"; then
  echo 'Unexpected host signing; artifact rejected'; exit 1
fi
echo 'CI build complete: real Apple toolchain ARM64 carrier, UNSIGNED; runtime and system host NOT_RUN.'
