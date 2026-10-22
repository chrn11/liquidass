#!/usr/bin/env python3
"""Negative mutation tests for guard_touch_and_capture.py (source only)."""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
GUARD = HERE / "guard_touch_and_capture.py"
BASELINE_ROOT = Path(os.environ.get(
    "LIQUIDASS_TOUCH_BASELINE_ROOT",
    str(HERE.parents[1]),
)).expanduser().resolve()
FILES = (
    "stage/validation/nativeplay/OwnedTouchRuntimeProbe.mm",
    "stage/Shared/LGLocalButtonMaterialView.mm",
    "stage/Shared/LGLocalButtonMaterialView.h",
    "stage/validation/nativeplay/LGDesignedLightGPUCapture.h",
)

sys.path.insert(0, str(HERE))
import guard_touch_and_capture as sourceguard  # noqa: E402


def source_at(root: Path, relative: str) -> Path:
    p = root / relative
    if p.is_file():
        return p
    if relative.startswith("stage/") and (root / relative[6:]).is_file():
        return root / relative[6:]
    raise FileNotFoundError(f"{relative} not found under {root}")


def make_repo_copy(parent: Path) -> Path:
    copied = parent / "repo"
    for rel in FILES:
        dest = copied / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source_at(BASELINE_ROOT, rel), dest)
    return copied


def mutate_method(root: Path, relative: str, selector: str, old: str, new: str) -> None:
    path = root / relative
    source = path.read_text(encoding="utf-8")
    matches = [m for m in sourceguard.extract_objc_methods(source) if m.selector == selector]
    if len(matches) != 1:
        raise AssertionError(f"wanted one {selector}, found {len(matches)}")
    method = matches[0]
    body = source[method.body_slice]
    if body.count(old) != 1:
        raise AssertionError(f"mutation needle must occur once in {selector}: {old!r}")
    changed = body.replace(old, new, 1)
    path.write_text(source[:method.open_brace] + changed + source[method.close_brace + 1:], encoding="utf-8")


class TouchCaptureGuardMutationTests(unittest.TestCase):
    def run_guard(self, root: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(GUARD), str(root)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )

    def with_repo(self, mutate):
        with tempfile.TemporaryDirectory(prefix="liquidass-touch-guard-") as temp:
            root = make_repo_copy(Path(temp))
            mutate(root)
            return self.run_guard(root)

    def assert_rejected(self, result, marker="FROZEN"):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(marker, result.stderr, result.stdout + result.stderr)

    def test_validated_baseline_passes(self):
        self.assertTrue(BASELINE_ROOT.is_dir(),
                        "set LIQUIDASS_TOUCH_BASELINE_ROOT to the read-only build29 source root")
        result = self.run_guard(BASELINE_ROOT)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_delete_super_begin_is_rejected(self):
        result = self.with_repo(lambda root: mutate_method(
            root, FILES[0], "-beginTrackingWithTouch:withEvent:",
            "BOOL originalResult=[super beginTrackingWithTouch:touch withEvent:event];",
            "BOOL originalResult=YES;",
        ))
        self.assert_rejected(result)

    def test_change_continue_return_is_rejected(self):
        result = self.with_repo(lambda root: mutate_method(
            root, FILES[0], "-continueTrackingWithTouch:withEvent:",
            "return originalResult;", "return YES;",
        ))
        self.assert_rejected(result)

    def test_remove_serial_greater_than_before_is_rejected(self):
        result = self.with_repo(lambda root: mutate_method(
            root, FILES[0], "-isActuallyCompletedSample:renderer:observedSerial:sourceKind:",
            "serial>before &&", "YES &&",
        ))
        self.assert_rejected(result)

    def test_cancel_cannot_be_relabelled_as_real_end(self):
        result = self.with_repo(lambda root: mutate_method(
            root, FILES[0], "-cancelCallback",
            "self.terminalTouchObserved=YES; self.touchCancelled=YES;",
            "self.terminalTouchObserved=YES; self.realTouchEndObserved=YES;",
        ))
        self.assert_rejected(result)

    def test_latest_request_identity_cannot_be_removed(self):
        result = self.with_repo(lambda root: mutate_method(
            root, FILES[0], "-latestRequestIsCompletedRelease",
            "sample==self.latestDrawSample &&", "YES &&",
        ))
        self.assert_rejected(result)

    def test_wrong_capture_source_is_rejected(self):
        result = self.with_repo(lambda root: mutate_method(
            root, FILES[1], "-drawInMTKView:",
            "source:frame.texture uniforms:uniforms", "source:drawable.texture uniforms:uniforms",
        ))
        self.assert_rejected(result, "WIRING")

    def test_disabling_framebuffer_only_is_rejected(self):
        result = self.with_repo(lambda root: mutate_method(
            root, FILES[1], "-initWithFrame:targetView:sourceProvider:allowApproximateSource:explicitOptIn:",
            "self.framebufferOnly=YES;", "self.framebufferOnly=NO;",
        ))
        self.assert_rejected(result, "DRAW")

    def test_capture_four_state_limit_is_semantically_guarded(self):
        result = self.with_repo(lambda root: mutate_method(
            root, FILES[3], "-candidateAndClaim:",
            "self.claimedStates.count>=4", "self.claimedStates.count>=5",
        ))
        self.assert_rejected(result, "STATE")

    def test_capture_helper_cannot_read_primary_drawable(self):
        injection = "\n    [drawable getBytes:NULL bytesPerRow:0 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];"
        result = self.with_repo(lambda root: mutate_method(
            root, FILES[3], "-encodeForCommand:device:pipeline:sampler:drawable:source:uniforms:state:contract:serial:",
            "NSString *name=[self candidateAndClaim:state];", "NSString *name=[self candidateAndClaim:state];" + injection,
        ))
        self.assert_rejected(result, "HELPER")

    def test_method_extractor_balances_nested_braces_comments_and_strings(self):
        sample = r'''@implementation Sample
- (void)target {
    NSString *text = @"} // /* not syntax";
    /* } { braces in a comment */
    void (^block)(void) = ^{ if (YES) { (void)@[@"{"]; } };
}
@end
'''
        methods = [m for m in sourceguard.extract_objc_methods(sample) if m.selector == "-target"]
        self.assertEqual(len(methods), 1)
        self.assertEqual(sample[methods[0].body_slice].count("@\"}"), 1)
        self.assertTrue(sample[methods[0].body_slice].endswith("}"))

    def test_renderer_subclass_in_guarded_sources_is_rejected(self):
        def add_subclass(root):
            path = root / FILES[2]
            with path.open("a", encoding="utf-8") as stream:
                stream.write("\n@interface ForbiddenRenderer : LGLocalButtonMaterialView @end\n")

        result = self.with_repo(add_subclass)
        self.assert_rejected(result, "SUBCLASS")

    def test_new_capture_wait_report_method_is_allowed(self):
        def add_helper(root):
            path = root / FILES[0]
            text = path.read_text(encoding="utf-8")
            marker = "- (void)cleanupFixture {"
            self.assertEqual(text.count(marker), 1)
            text = text.replace(marker,
                "- (void)temporaryCaptureSuiteWaitForReports { if (self.didCleanup) return; }\n" + marker, 1)
            path.write_text(text, encoding="utf-8")

        result = self.with_repo(add_helper)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
