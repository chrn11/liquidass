#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: this regression harness requires macOS and real Metal." >&2
  exit 2
fi
if (( $# > 2 )); then
  echo "Usage: $0 [repoRoot [outRoot]]" >&2
  exit 2
fi
scriptDir="$(cd "$(dirname "$0")" && pwd -P)"
repoRoot="${1:-$scriptDir/../liquidass-designed-light-hardening-main}"
repoRoot="$(cd "$repoRoot" && pwd -P)"
outRoot="${2:-$repoRoot/ci-artifacts/liquidass-capture-hardening-tests}"
mkdir -p "$outRoot"
outRoot="$(cd "$outRoot" && pwd -P)"
stageRoot="$repoRoot"
[[ -d "$stageRoot/Shared" ]] || stageRoot="$repoRoot/stage"
shared="$stageRoot/Shared"
helper="$stageRoot/validation/nativeplay"
sourceFile="$scriptDir/test_capture_macos.mm"
for required in "$sourceFile" "$shared/LGLocalButtonUniforms.h" \
  "$shared/LGLocalButtonShaderSource.h" "$helper/LGDesignedLightGPUCapture.h" \
  "$helper/LGDesignedLightExperimentPolicy.h"; do
  [[ -f "$required" ]] || { echo "ERROR: missing required input: $required" >&2; exit 2; }
done

matchApp="$outRoot/NativePlayLabHost.app"
otherApp="$outRoot/NonmatchingHost.app"
mkdir -p "$matchApp/Contents/MacOS" "$otherApp/Contents/MacOS"
write_plist() {
  local path="$1" bundleID="$2"
  cat > "$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$bundleID</string>
  <key>CFBundleExecutable</key><string>test</string>
  <key>CFBundleName</key><string>LiquidAss Capture Test Host</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
</dict></plist>
PLIST
}
write_plist "$matchApp/Contents/Info.plist" "org.liquidass.native-play-lab"
write_plist "$otherApp/Contents/Info.plist" "org.liquidass.capture-hardening-tests.nonmatch"
clangxx="$(xcrun --find clang++)"
"$clangxx" -x objective-c++ -std=c++17 -fobjc-arc -fblocks \
  -DLG_LOCAL_DESIGNED_LIGHT_EXPERIMENT=1 -DLG_LOCAL_BUTTON_RENDERER_COMPILED=1 \
  -I "$shared" -I "$helper" \
  "$sourceFile" -framework Foundation -framework Metal \
  -framework CoreGraphics -framework ImageIO \
  -o "$matchApp/Contents/MacOS/test"
chmod 755 "$matchApp/Contents/MacOS/test"
cp "$matchApp/Contents/MacOS/test" "$otherApp/Contents/MacOS/test"
chmod 755 "$otherApp/Contents/MacOS/test"
mkdir -p "$HOME/Documents"
echo "RUN: nonmatching bundle must reject helper init"
"$otherApp/Contents/MacOS/test" --expect-init-nil
echo "RUN: allowlisted host real-Metal capture regressions"
set +e
"$matchApp/Contents/MacOS/test" > "$outRoot/capture-tests.log" 2>&1
status=$?
set -e
cat "$outRoot/capture-tests.log"
mkdir -p "$outRoot/actual-capture-output"
for dir in "$HOME"/Documents/LGDesignedLightGPUCapture_*; do
  [[ -d "$dir" ]] || continue
  cp -R "$dir" "$outRoot/actual-capture-output/"
done
if [[ "$status" -eq 0 ]]; then
  echo "PASS: capture regression harness"
else
  if [[ "$status" -eq 77 ]]; then
    echo "NOT_RUN: real Metal device unavailable; exit 77 is not PASS" >&2
    exit 77
  fi
  echo "FAIL: capture regression harness exited $status" >&2
  exit "$status"
fi
