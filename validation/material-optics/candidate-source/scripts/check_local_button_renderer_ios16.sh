#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK=${SDK:-/var/minis/shared/ios-re-tools/rh-theos/sdks/iPhoneOS16.5.sdk}
if [ ! -d "$SDK" ]; then
  command -v xcrun >/dev/null || { echo 'Missing SDK and xcrun' >&2; exit 1; }
  SDK=$(xcrun --sdk iphoneos --show-sdk-path)
fi
CXX=${CXX:-clang++}
for ARCH in arm64 arm64e; do
  for ENABLED in 0 1; do
    "$CXX" -fsyntax-only -x objective-c++ -std=c++17 -Werror=return-type \
      -Werror=objc-method-access -Werror=protocol -fobjc-arc -fblocks \
      -DLG_LOCAL_BUTTON_RENDERER_COMPILED="$ENABLED" \
      -target "${ARCH}-apple-ios16.5" -isysroot "$SDK" \
      -I"$ROOT/Shared" "$ROOT/Shared/LGLocalButtonMaterialView.mm"
    echo "PASS final local renderer SDK $ARCH compileGate=$ENABLED"
  done
done
