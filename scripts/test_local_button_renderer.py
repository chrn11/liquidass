#!/usr/bin/env python3
"""Narrow static wiring/source identity checks; not a Metal runtime claim."""
from pathlib import Path
import hashlib, json, re, subprocess, sys
root=Path(__file__).resolve().parents[1]
legacy=(root/'scripts/legacy_local_button_shader_fixture.h').read_text()
legacy_body=re.search(r'R"LGLOCALMSL\((.*?)\)LGLOCALMSL";',legacy,re.S).group(1)
assert hashlib.sha256(legacy_body.encode()).hexdigest()=='f21b394471fd9d3983502441852e3be0664eec7614a7bcd7652939077c06a72b'
shader=(root/'Shared/LGLocalButtonShaderSource.h').read_text()
body=re.search(r'R"LGLOCALMSL\((.*?)\)LGLOCALMSL";',shader,re.S).group(1)
shader_sha=hashlib.sha256(body.encode()).hexdigest()
assert shader_sha=='c4dc2e5bcf9080c31a38770637da705d292cbbf7544e43dd30a0d41677541551'
assert 'LGButtonOpticsEvaluateWithContact' in body and 'LGButtonOpticsEvaluate' in body and 'struct Uniforms {' in body
formula=root/'Shared/LGButtonOpticsFormula.inc'
assert b'LGButtonOpticsEvaluateWithContact' in formula.read_bytes()
assert b'LGButtonOpticsEvaluate,' in formula.read_bytes()
impl=(root/'Shared/LGLocalButtonMaterialView.mm').read_text()
assert 'newLibraryWithSource:source' in impl and 'kLGLocalButtonCandidateMSL' in impl
assert 'LGLocalValidateSourceContract' in impl and 'isOwnerInstanceAlive:' in impl
assert 'LGLocalButtonBuildUniforms' in impl
uniforms=(root/'Shared/LGLocalButtonUniforms.h').read_text()
assert 'u.glassThickness=pressure.thickness' in uniforms and 'u.refractionScale=pressure.refractionScale' in uniforms
assert 'host->glassThickness' in uniforms and 'host->refractionScale' in uniforms
assert 'MTLBlendFactorSourceAlpha;' not in impl
assert 'color.sourceRGBBlendFactor=MTLBlendFactorOne;' in impl
assert 'self.layer.masksToBounds=YES;' in impl
assert 'LGLocalSourceAcceptOrder' in impl and 'frame.texture.device!=self.device' in impl
assert 'sourceExpiryTimer' in impl and 'repeats:NO' in impl
assert 'completed.status==MTLCommandBufferStatusCompleted' in impl
assert 'dispatch_semaphore_create(3)' in impl and 'addCompletedHandler' in impl
assert 'CADisplayLink' not in impl and 'renderInContext' not in impl and 'drawViewHierarchyInRect' not in impl
assert 'isSystemLiveBackdrop { return NO; }' in impl
api=(root/'Shared/LGLocalButtonMaterialView.h').read_text()
assert 'targetView:(UIView *)targetView' in api and 'explicitOptIn:(BOOL)explicitOptIn' in api
assert 'userInteractionEnabled' not in api
subprocess.run([sys.executable,str(root/'scripts/generate_local_button_shader.py')],check=True)
shader2=(root/'Shared/LGLocalButtonShaderSource.h').read_text()
assert hashlib.sha256(shader2.encode()).hexdigest()==hashlib.sha256(shader.encode()).hexdigest()
print('frozen legacy 208-byte shader + regenerated shared contact MSL/hash, API/source/ABI wiring: PASS')
print('Structural Python checks only; macOS CI script owns C, Metal GPU, and iOS SDK tests.')
