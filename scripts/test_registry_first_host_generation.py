#!/usr/bin/env python3
"""Fail if first-bind accidentally reintroduces the nil-record generation bug."""
from pathlib import Path
import re
import sys

path = Path(__file__).resolve().parents[1] / "Shared/LGGlassKit.x"
source = path.read_text()
marker = "void lgTrackGlass(UIView *glass"
start = source.find(marker)
end = source.find("BOOL LGDescribeMaterialSurface", start)
if start < 0 or end < 0:
    sys.exit("FAIL: tracker/query functions not found")
block = source[start:end]
new_record = block.find("record.hostGeneration = LGGlassKitNextHostGeneration();")
first_write = block.find("current.hostGeneration = record.hostGeneration;", new_record)
if new_record < 0 or first_write < new_record:
    sys.exit("FAIL: new host record is not the generation source for first descriptor write")
new_segment = block[new_record:first_write]
if "existing.hostGeneration" in new_segment:
    sys.exit("FAIL: first bind reads generation from existing (nil) record")
# Existing records derive from their saved generation, and commit after binding.
existing = block[:new_record]
if ("uint64_t hostGeneration = existing.hostGeneration;" not in existing or
        "current.hostGeneration = hostGeneration;" not in existing):
    sys.exit("FAIL: existing-record update path lost stable host generation")
if existing.index("existing.material = material;") < existing.index("if (![glassView lgUpdateSurfaceDescriptor:current])"):
    sys.exit("FAIL: owner record committed before descriptor acceptance")
first = block[new_record:]
if first.index("[sGlassRecs setObject:record forKey:glassView];") < first.index("if (![glassView lgUpdateSurfaceDescriptor:current])"):
    sys.exit("FAIL: first record committed before descriptor acceptance")
query_start = source.index("BOOL LGDescribeMaterialSurface")
query_end = source.index("void lgSuppressStock", query_start)
query = source[query_start:query_end]
assert "record.material != material" in query
assert "value.captureOwnerGeneration != record.hostGeneration" in query
assert "[sGlassRecs setObject:" not in query
assert "lgTrackGlass(" not in query
live = (path.parent / "LGLiveBackdropView.m").read_text()
snapshot = live[live.index("- (LGSurfaceDescriptorV1)lgPresentationSurfaceDescriptor"):
                live.index("- (BOOL)lgUpdateSurfaceDescriptor")]
assert "value.captureOwnerGeneration != ownerGeneration" in snapshot
assert "value.captureOwnerGeneration =" not in snapshot
assert "_lgSurfaceDescriptor =" not in snapshot
assert "LGSurfaceGenerationNext" not in snapshot
ready = source[source.index("BOOL LGMaterialGlassReady"):
               source.index("void LGRegisterMaterialHost")]
assert "LGDescribeMaterialSurface" not in ready
assert "lgFilterAttached" in ready
assert "Legacy helpers such as the fullscreen Passcode UIView tint" in block
assert "[sGlassRecs setObject:helper forKey:glass]" in block
assert "if (!LGSurfaceGeometryEqual(&_lgSurfaceDescriptor, &value)" in snapshot
print("PASS: first-bind source, idempotence, owner-bound pure query, CA readiness isolation, legacy UIView lifecycle")
