#!/usr/bin/env python3
"""Checks generation-bearing descriptor patch producers and helper semantics."""
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
ABI = ROOT / "Shared/LGSurfaceDescriptor.h"
CODE = r'''#include <assert.h>
#include "LGSurfaceDescriptor.h"
int main(void) {
    LGSurfaceDescriptorV1 current = LGSurfaceDescriptorV1MakeDefault(LGSurfaceRolePanel, 1);
    LGSurfaceDescriptorV1 next = current;
    next.hostGeneration = 11; next.captureOwnerGeneration = 11;
    assert(LGSurfaceDescriptorCanBindHostGeneration(&current, 0, &next));
    current = next;
    next.interactionGeneration++;
    assert(LGSurfaceDescriptorCanBindHostGeneration(&current, 1, &next));
    current = next;
    next.hostGeneration = 12; next.captureOwnerGeneration = 12;
    assert(LGSurfaceDescriptorCanBindHostGeneration(&current, 1, &next));
    current = next;
    next.hostGeneration = 11; next.captureOwnerGeneration = 11;
    assert(!LGSurfaceDescriptorCanBindHostGeneration(&current, 1, &next));
    return 0;
}'''
with tempfile.TemporaryDirectory(prefix="surface-generation-") as d:
    src, binpath = Path(d)/"t.c", Path(d)/"t"
    src.write_text(CODE)
    subprocess.run(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-I", str(ABI.parent), str(src), "-o", str(binpath)], check=True)
    subprocess.run([str(binpath)], check=True)
root_source=(ROOT/"Shared/LGGlassKit.x").read_text()
track=root_source[root_source.index("void lgTrackGlass"):root_source.index("BOOL LGDescribeMaterialSurface")]
new_record=track.index("record.hostGeneration = LGGlassKitNextHostGeneration()")
assert "current.hostGeneration = record.hostGeneration" in track[new_record:]
assert "uint64_t hostGeneration = existing.hostGeneration;" in track[:new_record]
assert "current.hostGeneration = hostGeneration;" in track[:new_record]
print("PASS: first-bind generation, idempotent refresh, monotone rebind, stale rejection")
