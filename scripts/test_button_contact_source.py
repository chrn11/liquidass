#!/usr/bin/env python3
"""Read-only source/hash gate for the local contact MSL build."""
from pathlib import Path
import hashlib, re, subprocess, sys, tempfile
ROOT=Path(__file__).resolve().parents[1]
SHARED=ROOT/'Shared'
GEN=ROOT/'scripts/generate_local_button_shader.py'
with tempfile.TemporaryDirectory() as td:
    msl=Path(td)/'candidate.metal'
    subprocess.run([sys.executable,str(GEN),'--msl-out',str(msl)],check=True)
    source=msl.read_text()
header=(SHARED/'LGLocalButtonShaderSource.h').read_text()
raw=re.search(r'kLGLocalButtonCandidateMSL\[\]\s*=\s*R"LGLOCALMSL\((.*)\)LGLOCALMSL";',header,re.S)
assert raw, 'generated raw MSL body missing'
assert raw.group(1)==source, 'header body differs from regenerated raw MSL'
digest=hashlib.sha256(source.encode()).hexdigest()
assert re.search(r'kLGLocalButtonCandidateMSLSHA256\[\]\s*=\s*"'+digest+r'";',header)
view=(SHARED/'LGLocalButtonMaterialView.mm').read_text()
assert re.search(r'kExpectedLocalShaderSHA256\[\]\s*=\s*"'+digest+r'";',view), 'runtime shader pin drift'
baseText=(ROOT/'LiquidAssBackboardd/Tweak.mm').read_text()
rawBase=re.search(r'kShaderSrc\s*=\s*R"MSL\((.*?)\)MSL";',baseText,re.S)
assert rawBase, 'frozen raw shader body missing'
base=rawBase.group(1)
marker='//__LG_BUTTON_OPTICS_FORMULA__'
assert base.count(marker)==1 and base.index(marker)<base.index('LGButtonOpticsEvaluate('), 'raw marker/call order drift'
assert 'buttonContactCenter' not in base, 'local-only contact ABI leaked into Backboard path'
assert source.count('LGButtonOpticsResult LGButtonOpticsEvaluateWithContact(')==1
assert source.count('LGButtonOpticsResult optics = LGButtonOpticsEvaluateWithContact(')==1
assert source.index('LGButtonOpticsResult LGButtonOpticsEvaluateWithContact(') < source.index('LGButtonOpticsResult optics = LGButtonOpticsEvaluateWithContact('), 'contact function call is not defined first'
assert 'u.buttonContactEnabled > 0.5f, u.buttonContactCenter.x' in source
assert 'u.buttonContactCenter.y, u.buttonContactPressure' in source
assert source.count('float2 buttonContactCenter;')==1
assert source.count('float buttonContactPressure;')==1
assert source.count('float buttonContactEnabled;')==1
assert 'LGBO_STMT' not in source, 'formula DSL did not expand into raw MSL'
assert 'subprocess' not in GEN.read_text() and 'clang' not in GEN.read_text(), 'generator must not compile locally'
formula=(SHARED/'LGButtonOpticsFormula.inc').read_text()
assert 'contactShapeGradientX' in formula and 'contactGradientY' in formula
assert 'LGButtonOpticsEvaluateWithContact' in formula
state=(SHARED/'LGButtonOpticalState.h').read_text()
assert 'touchValid' in state and 's->touchValid=false;' in state
assert 's->touchValid=true;' in state
uniform=(SHARED/'LGLocalButtonUniforms.h').read_text()
for marker in ('sizeof(LGLocalButtonUniforms)==224','buttonContactCenter)==208','buttonContactPressure)==216','buttonContactEnabled)==220'):
    assert marker in uniform, 'CPU ABI assertion missing: '+marker
assert 'explicitLocalOptIn && state->touchValid && contactPhase' in uniform
assert 'state->phase==LGOpticalTrackingInside' in uniform and 'state->phase==LGOpticalTrackingOutside' in uniform
assert 'state->phase==LGOpticalReleasing' in uniform and 'state->phase==LGOpticalCancelled' in uniform
print(f'PASS contact source/hash/marker/ABI structural contract sha256={digest}')
