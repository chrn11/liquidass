#!/bin/bash
set -euo pipefail
R="$(cd "$(dirname "$0")/../.." && pwd)"
O="$R/ci-artifacts/ca-closed-profile"
mkdir -p "$O/logs"
exec > >(tee "$O/logs/build.log") 2>&1
test "$(uname -s)" = Darwin
V="$R/validation/ca-closed-profile"
python3 "$V/sourceguard.py" "$R"
python3 "$V/compile_body_macos.py" "$R" "$O/body-compile" "${SDK:?Pinned iOS SDK required}"
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror -I"$R/Shared" "$V/test_host_policy.c" -framework CoreGraphics -lm -o "$O/host-policy-test"
"$O/host-policy-test"
xcrun --sdk macosx clang++ -std=c++17 -fobjc-arc -fblocks -I"$R/Shared" \
  "$V/CAOriginalSourceIdentity.mm" -framework Foundation -o "$O/original-source-identity"
"$O/original-source-identity" "$V/frozen149/Tweak.mm" "$O/actual-original-runtime.metal"
xcrun --sdk iphoneos metal -c "$V/generated/LiquidAssCAClosed.metal" -o "$O/ca-closed.air"
xcrun --sdk iphoneos metallib "$O/ca-closed.air" -o "$O/ca-closed.metallib"
bash "$V/run-ca-closed-tests.sh" "$R" "$O/gpu"
echo 'Complete: actual isolated body source Apple-compiled and real MacGPU controls. NO App, device, system daemon install, preferences, injection or restart.'
