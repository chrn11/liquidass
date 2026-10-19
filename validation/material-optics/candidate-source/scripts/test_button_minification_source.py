#!/usr/bin/env python3
"""Pure-Python structure checks; no shader or CPU material rendering."""
from pathlib import Path
import hashlib, re, sys

ROOT=Path(__file__).resolve().parents[1]
if len(sys.argv)!=2:
    raise SystemExit('usage: test_button_minification_source.py generated.metal')
msl=Path(sys.argv[1]).read_text()
helper=(ROOT/'Shared/LGLocalMinification.inc').read_text()
generator=(ROOT/'scripts/generate_local_button_shader.py').read_text()
formula=(ROOT/'Shared/LGButtonOpticsFormula.inc').read_bytes()
manifest=ROOT/'docs/natural-volume-candidate-manifest.json'
# This is an explicitly different optical model, not an AA-only identity claim.
assert hashlib.sha256(formula).hexdigest()=='3d6c8499a2f235246db942b86366f3e330aaea7eeef7c741e589c914528175b9'
assert b'LGBOSmoothCappedLength(LGBOMax(out.height, 0.0f), displacementCap)' in formula
assert b'out.environmentWeight = 0.0f' in formula
assert b'out.environmentOffsetX = out.offsetX' in formula
assert 'out.tapCount=1' in helper and 'if (major<=1.0f)' in helper
assert 'kernelXX' in helper and 'kernelXY' in helper and 'kernelYY' in helper
assert 'LGBOMinificationExcess' in helper and 'support*support-1.0f' in helper
assert 'axisX' not in helper and 'tapCount = major <=' not in helper
assert 'LGBOClamp(major,1.0f,4.0f)' in helper
assert msl.startswith('#define LG_BUTTON_OPTICS_COMPILED 1\n')
assert len(re.findall(r'localButtonEvaluateAt\(float2\(px\.x',msl))==4
assert 'LGMinificationFootprint opticalFootprint=' in msl
assert msl.index('LGMinificationFootprint opticalFootprint=') < msl.index('float4 opticalSample;')
assert 'opticalSample=src.sample(s,localButtonSourceUV(src,u,opticalUV));' in msl
assert 'environmentSample=src.sample(s,localButtonSourceUV(src,u,environmentUV));' in msl
assert msl.count('localButtonMinifiedSample(src,s,')==2
assert 'source.sample(s,a,level(0.0f))' in msl and 'source.sample(s,e,level(0.0f))' in msl
assert '3.0f*footprint.kernelXX+footprint.kernelXY' in msl
assert not re.search(r'\b(?:ddx|ddy)\s*\(',msl)
assert 'filter::linear, address::clamp_to_edge' in msl
assert '#include "LGLocalMinification.inc"' in (ROOT/'Shared/LGButtonMaterialCandidate.h').read_text()
assert 'immutableUntilFrameReleased' in (ROOT/'Shared/LGLocalButtonSourceContract.h').read_text()
assert 'LG_LOCAL_BUTTON_MAX_OVERSCAN_PADDING_POINTS 16.0' in (ROOT/'Shared/LGLocalButtonSourceContract.h').read_text()
header=(ROOT/'Shared/LGLocalButtonShaderSource.h').read_text()
digest=re.search(r'kLGLocalButtonCandidateMSLSHA256\[\] = "([0-9a-f]{64})"',header)
assert digest and digest.group(1)==hashlib.sha256(msl.encode()).hexdigest()
assert "expand_formula(SHARED/'LGLocalMinification.inc')" in generator
assert 'opticalFootprint' in generator and 'environmentFootprint' in generator
assert 'level(0.0f)' in generator
print('PASS pure-Python minification source invariants; no compiler/GPU inference')
