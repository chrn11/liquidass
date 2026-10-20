#!/usr/bin/env python3
"""SDK syntax checks only, NOT a linked package build or device validation."""
from pathlib import Path
import os
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
THEOS = Path(os.environ.get("THEOS", "/var/minis/shared/ios-re-tools/rh-theos"))
SDK = THEOS/"sdks/iPhoneOS16.5.sdk"
for p in (SDK, THEOS/"vendor/logos/bin/logos.pl"):
    if not p.exists(): raise SystemExit(f"Missing validation dependency: {p}")
arch = os.environ.get("SURFACE_ARCH", "arm64")
common = ["-fsyntax-only", "-ferror-limit=8", "-fobjc-arc", "-target", f"{arch}-apple-ios16.5",
          "-isysroot", str(SDK)]
for p in (THEOS/"include", THEOS/"include/iphone", THEOS/"vendor/include", ROOT/"Shared"):
    common += ["-I", str(p)]
with tempfile.TemporaryDirectory(prefix="lg-sdk-check-") as directory:
    for name in ("Shared/LGGlassKit.x", "Hooks/Alerts.x", "Hooks/Clock.x",
                 "Hooks/Controls.x", "Hooks/CoverSheet.x", "Hooks/QuickActions.x"):
        generated = Path(directory)/(Path(name).stem+".m")
        with generated.open("w") as out:
            subprocess.run(["perl", str(THEOS/"vendor/logos/bin/logos.pl"),
                            "-c", "generator=libhooker", str(ROOT/name)], stdout=out, check=True)
        subprocess.run(["clang", *common, "-x", "objective-c", str(generated)], check=True)
        print(f"PASS SDK {arch}: {name}", flush=True)
    subprocess.run(["clang", *common, "-x", "objective-c",
                    str(ROOT/"Shared/LGLiveBackdropView.m")], check=True)
    print(f"PASS SDK {arch}: Shared/LGLiveBackdropView.m", flush=True)
    subprocess.run(["clang", *common, "-x", "objective-c",
                    str(ROOT/"LiquidAssPrefs/LGPRootListController.m")], check=True)
    print(f"PASS SDK {arch}: LiquidAssPrefs/LGPRootListController.m", flush=True)
    subprocess.run(["clang++", *common, "-std=c++17", "-fno-objc-arc-exceptions",
                    str(ROOT/"LiquidAssBackboardd/Tweak.mm")], check=True)
    print(f"PASS SDK {arch}: LiquidAssBackboardd/Tweak.mm", flush=True)
print("PASS: syntax only; no linking, install, process restart or pixel acceptance")
