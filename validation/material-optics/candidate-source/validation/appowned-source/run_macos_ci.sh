#!/usr/bin/env bash
set -euo pipefail

: "${SOURCE_ROOT:?set SOURCE_ROOT to the patch-applied candidate root}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Portable, value-only helper tests: compiled and run on macOS CI, never iSH.
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror \
  -I "$SOURCE_ROOT/Shared" \
  "$HERE/test_appowned_lease_policy.c" -framework CoreGraphics \
  -o "$TMP/appowned-policy-tests"
"$TMP/appowned-policy-tests"

# iOS SDK syntax-only check for the real UIKit/Metal provider and the XCTest
# host-test source. Runtime assertions belong to the existing iOS test host.
xcrun --sdk iphonesimulator clang -target arm64-apple-ios16.0-simulator \
  -fsyntax-only -fobjc-arc -fmodules -std=c++17 \
  -DLG_LOCAL_BUTTON_RENDERER_COMPILED=1 \
  -I "$SOURCE_ROOT/Shared" -I "$HERE" \
  -framework UIKit -framework MetalKit -framework QuartzCore -framework XCTest \
  "$SOURCE_ROOT/Shared/LGAppOwnedButtonSourceProvider.mm" \
  "$HERE/LGAppOwnedButtonSourceProviderTests.mm"
