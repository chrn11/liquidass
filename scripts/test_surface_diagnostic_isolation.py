#!/usr/bin/env python3
"""Source-boundary assertions; these do not prove runtime behavior or pixels."""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
back=(ROOT/"LiquidAssBackboardd/Tweak.mm").read_text()
render=back[back.index("static void ourCustomRender13") : back.index("__attribute__((constructor))\nstatic void tweakInit")]
assert "LGSurfaceDiagnostic" not in render
assert "g_surfaceDiagnostic" not in render
receiver=back[back.index("/* Diagnostic-only receiver.") : back.index("static void lgPrefsReloadCallback")]
assert "g_surfaceDiagnosticLatest" not in receiver
assert "exchange(true" in receiver and "AcceptNotifications.load" in receiver
assert "LGSurfaceDiagnosticReadExact" in receiver and "LGSurfaceDiagnosticAccept" in receiver
assert "atom" in receiver[:150]  # explicit no-atom-lookup contract comment
assert "g_hostParams" not in receiver and "Uniforms" not in receiver
kit=(ROOT/"Shared/LGGlassKit.x").read_text()
publisher=kit[kit.index("static dispatch_source_t sSurfaceDiagnosticTimer") : kit.index("BOOL LGDescribeMaterialSurface")]
assert '@"com.apple.springboard"' in publisher
assert "LG_SURFACE_DIAGNOSTICS_PREF" in publisher
assert "LGSurfaceDiagnosticWriteAtomic" in publisher
assert "sSurfaceDiagnosticWriting" in publisher
assert "dispatch_source_set_timer" in publisher and "NSEC_PER_SEC" in publisher
io=(ROOT/"Shared/LGSurfaceDiagnosticIO.h").read_text()
assert "mmap(" not in io
assert "mkstemps(" in io and "rename(" in io and "O_NOFOLLOW" in io
print("PASS: default-gated SpringBoard diagnostics, bounded notification entry, no render callback or uniform consumer")
