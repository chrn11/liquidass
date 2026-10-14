#!/usr/bin/env python3
"""Narrow static wiring/source identity checks; not a Metal runtime claim."""
from pathlib import Path
import hashlib, json, re, subprocess, sys
root=Path(__file__).resolve().parents[1]
base=Path('/var/minis/shared/liquidass-button-integrated-candidate-6a5e4afc-3ed5-48c6-a401-d20cbe5bccff')
manifest=Path('/var/minis/workspace/liquidass-button-interaction-main/integrated-source-manifest.json')
m=json.loads(manifest.read_text())
assert m['sourceCount']==114 and len(m['allSourceSHA256'])==114
for rel,digest in m['allSourceSHA256'].items():
    p=root/rel
    assert p.is_file() and hashlib.sha256(p.read_bytes()).hexdigest()==digest, rel
shader=(root/'Shared/LGLocalButtonShaderSource.h').read_text()
body=re.search(r'R"LGLOCALMSL\((.*?)\)LGLOCALMSL";',shader,re.S).group(1)
shader_sha=hashlib.sha256(body.encode()).hexdigest()
assert shader_sha=='f21b394471fd9d3983502441852e3be0664eec7614a7bcd7652939077c06a72b'
assert 'LGButtonOpticsEvaluate' in body and 'struct Uniforms {' in body
formula=root/'Shared/LGButtonOpticsFormula.inc'
assert hashlib.sha256(formula.read_bytes()).hexdigest()=='a602854cff8a36526024cc0a5b9a538831ebcc426681fbcca17119e75e0cc0d6'
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
subprocess.run([sys.executable,str(root/'scripts/generate_local_button_shader.py')],check=True,capture_output=True,text=True)
shader2=(root/'Shared/LGLocalButtonShaderSource.h').read_text()
assert hashlib.sha256(shader2.encode()).hexdigest()==hashlib.sha256(shader.encode()).hexdigest()
print('baseline114 freeze, actual kShaderSrc + shared .inc => candidate MSL SHA, API/source/ABI wiring: PASS')
print('Pure source/C checks only; execute check_local_button_renderer_ios16.sh for final SDK results. Runtime is separately recorded.')
