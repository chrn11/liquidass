#!/usr/bin/env python3
"""Mechanical source guards only; does not compile or execute Objective-C/C."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
BASE_MANIFEST = Path("/var/minis/workspace/liquidass-button-overscan-main/main-final-manifest.json")
if not BASE_MANIFEST.is_file():
    raise SystemExit(f"missing authoritative baseline manifest: {BASE_MANIFEST}")
manifest = json.loads(BASE_MANIFEST.read_text())
base_hashes = manifest["finalSourceSHA256"]
assert manifest["finalSourceCount"] == 135 and len(base_hashes) == 135
changed_existing = {
    "Makefile",
    "Hooks/Controls.x",
    "Shared/LGLocalButtonMaterialView.h",
    "Shared/LGLocalButtonMaterialView.mm",
}
for rel, expected in base_hashes.items():
    path = ROOT / rel
    assert path.is_file(), f"baseline source missing: {rel}"
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if rel not in changed_existing:
        assert actual == expected, f"unrelated baseline source changed: {rel}"
    else:
        assert actual != expected, f"expected narrow patch missing: {rel}"

controls = (ROOT / "Hooks/Controls.x").read_text()
view_h = (ROOT / "Shared/LGLocalButtonMaterialView.h").read_text()
view_mm = (ROOT / "Shared/LGLocalButtonMaterialView.mm").read_text()
api_h = (ROOT / "Shared/LGSettingsBackButtonLocalBinding.h").read_text()
contract = (ROOT / "Shared/LGLocalButtonSourceContract.h").read_text()
makefile = (ROOT / "Makefile").read_text()
state_c = (ROOT / "scripts/test_settings_back_button_local_state.c").read_text()

# Narrow, exact public binding and opt-in.
assert "Shared/LGLocalButtonMaterialView.mm" in makefile
assert "Metal MetalKit" in makefile
assert "#define LG_LOCAL_BUTTON_RENDERER_COMPILED 0" in contract
assert 'PrefsButton.LocalRenderer.Enabled' in api_h
assert "[value isKindOfClass:NSNumber.class] && [value boolValue]" in controls
assert "object_getClass(target) != LGSettingsBackButton.class" in controls
assert 'com.apple.Preferences' in controls
assert '_UINavigationBarContentView' in controls and '_UIButtonBarButton' in controls
assert '_UIBackButtonMaskView' in controls
assert "fabs(CGRectGetWidth(self.bounds)-44.0)<0.01" in controls
assert "CGAffineTransformIsIdentity(self.transform)" in controls
assert "!self.isTracking" in controls and "self.opticalState.pressure == 0.0f" in controls
assert "extern \"C\"" in api_h and "extern \"C\"" in controls
assert "LGSettingsBackButtonBindLocalButtonSourceProvider" in api_h and "LGSettingsBackButtonBindLocalButtonSourceProvider" in controls
assert "[self lg_localUnbindRenderer]" in controls

# One established reducer/state; actual snapshot goes to the already-tested renderer.
assert "legacyOptedIn || localOptedIn" in controls
assert "submitOpticalState:_opticalState enabled:localOptedIn" in controls
assert "LGOpticalBegin(&_opticalState" in controls
assert "point.x - CGRectGetMinX(self.bounds)" in controls
assert "point.y - CGRectGetMinY(self.bounds)" in controls
assert "LGOpticalSetEligibility" in state_c and "legacyPressureGate = false" in state_c
assert "LGOpticalBegin" in state_c and "LGOpticalEnd" in state_c
assert "struct LGLocal" not in controls and "LGLocalButtonOpticalState" not in controls

# Availability is tied to the current serial + completed command + valid frame.
assert "availabilityChangedHandler" in view_h
assert "hasCurrentCompletedValidSubmission" in view_h
assert "hasCurrentValidSourceFrame" in view_h
completed = view_mm.index("BOOL succeeded=completed.status==MTLCommandBufferStatusCompleted")
valid = view_mm.index("!succeeded || ![strongSelf frameStillValid:retainedFrame", completed)
serial = view_mm.index("strongSelf.lastCompletedSubmissionSerial=serial", valid)
notify_true = view_mm.index("[strongSelf publishAvailability:YES]", serial)
assert completed < valid < serial < notify_true
assert "strongSelf.submissionSerial==serial" in view_mm
assert "self.lastCompletedSubmissionSerial==self.submissionSerial" in view_mm
start=view_mm.index('self.lastCommandBufferSucceeded=NO;',view_mm.index('self.sourceFrame=frame'))
revoked=view_mm.index('[self publishAvailability:NO]',start)
reentry=view_mm.index('self.submissionSerial!=serialBeforeAvailabilityCallback',revoked)
serial_advance=view_mm.index('self.submissionSerial++;',reentry)
assert start<revoked<reentry<serial_advance
assert 'self.sourceFrame!=frame || !self.hasStateSnapshot' in view_mm
assert 'bindMaterialViewForFeedbackExclusion:renderer device:renderer.device' in controls
assert 'updateTargetGeometryGeneration:_opticalState.geometryGeneration' in controls
clear = view_mm.index("- (void)clearLocalFrame {")
clear_end = view_mm.index("- (BOOL)targetCanRender", clear)
clear_body = view_mm[clear:clear_end]
assert clear_body.index("self.sourceFrame=nil") < clear_body.index("[self publishAvailability:NO]")
assert "dispatch_async(dispatch_get_main_queue()" in view_mm
assert "KVO" not in view_mm and "addObserver:self forKeyPath:@\"hidden\"" not in view_mm

# Only the old glass object can be hidden/restored; local visual scale is conditional.
assert "self.localFallbackGlass = self.glass" in controls
assert "fallback == self.glass && fallback.hidden" in controls
assert "fallback.hidden = self.localFallbackWasHidden" in controls
assert "self.glass.hidden = YES" in controls
assert "if (available && !self.localOpticalPressArmed && !idleCompleted) return;" in controls
assert "view.hasCurrentCompletedValidSubmission;" in controls
assert "stockButton.hidden" not in controls and "glyph.hidden" not in controls
highlight = controls[controls.index("- (void)setHighlighted:(BOOL)highlighted {", controls.index("@implementation LGSettingsBackButton")):controls.index("- (BOOL)lg_invokeView", controls.index("@implementation LGSettingsBackButton"))]
assert highlight.index("idleCompleted") < highlight.index("strongSelf.transform = highlighted ? CGAffineTransformMakeScale(1.16, 1.16)")
assert "CGAffineTransformMakeScale(1.16, 1.16)" in highlight
assert "lg_opticalSubmit" in controls and "[self.localMaterialView submitOpticalState:_opticalState" in controls
assert "window.snapshotView" not in controls and "superview.backgroundColor" not in controls

# Critical numerical/material/provider ABI files remain exactly baseline-identical.
for rel in ("Shared/LGLocalButtonSourceContract.h", "Shared/LGLocalButtonUniforms.h",
            "Shared/LGLocalButtonShaderSource.h", "Shared/LGButtonOpticalState.h",
            "Shared/LGButtonPressureRoute.h", "LiquidAssBackboardd/Tweak.mm"):
    assert hashlib.sha256((ROOT / rel).read_bytes()).hexdigest() == base_hashes[rel], rel

print("PASS local binding/source guards; no compiler/runtime/device test executed")
