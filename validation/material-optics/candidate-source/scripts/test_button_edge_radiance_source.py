#!/usr/bin/env python3
"""Mechanical source checks only; does not compile C, ObjC++, or Metal."""
from pathlib import Path
import hashlib
import re

ROOT=Path(__file__).resolve().parents[1]
formula=(ROOT/'Shared/LGButtonOpticsFormula.inc').read_text()
generator=(ROOT/'scripts/generate_local_button_shader.py').read_text()
header=(ROOT/'Shared/LGLocalButtonShaderSource.h').read_text()

m=re.search(r'kLGLocalButtonCandidateMSL\[\]\s*=\s*R"LGLOCALMSL\((.*?)\)LGLOCALMSL";',header,re.S)
assert m, 'generated candidate MSL raw string missing'
msl=m.group(1)
actual=hashlib.sha256(msl.encode()).hexdigest()
pin=re.search(r'kLGLocalButtonCandidateMSLSHA256\[\]\s*=\s*"([0-9a-f]{64})"',header)
assert pin and pin.group(1)==actual, 'generated header pin does not match MSL bytes'

assert formula.count('out.environmentWeight = 0.0f;')==2, 'shared/default API must retain zero secondary weight'
legacy= formula.split('LGBO_FUNCTION_BEGIN(LGButtonOpticsResult, LGButtonOpticsEvaluate,',1)[1].split('LGBO_FUNCTION_END',1)[0]
assert 'LGBOImageEdgeRadianceWeight(' not in legacy, 'legacy wrapper must not opt in'
assert 'optics.environmentWeight=LGBOImageEdgeRadianceWeight(' in generator
assert 'optics.environmentWeight=LGBOImageEdgeRadianceWeight(' in msl
assert 'u.buttonSourceOverscanEnabled > 0.5f && optics.environmentWeight > 0.0f' in msl
assert 'environmentSample=opticalSample;' in msl, 'zero/off path must reuse primary sample'
assert 'environmentSample=src.sample' not in msl, 'no second clear image sample'

start=msl.index('float4 localButtonEdgeRadianceSample(')
end=msl.index('\n}',start)+2
edge=msl[start:end]
assert edge.count('src.sample(s,')==4, 'radiance integral must use exactly four extra taps'
assert 'LGBOAverageFourRadianceSamples(a.r,b.r,c.r,d.r)' in edge
assert 'legalPad=float2(16.0f*u.buttonCandidatePointScale)/dimensions' in edge
assert 'lowUV=max(halfTexel,roiMin-legalPad)' in edge
assert 'legalHighUV=min(highUV,roiMax+legalPad)' in edge
assert 'clamp((center+radial)/dimensions,lowUV,legalHighUV)' in edge
assert 'clamp((center-radial)/dimensions,lowUV,legalHighUV)' in edge
assert 'clamp((center+lateral)/dimensions,lowUV,legalHighUV)' in edge
assert 'clamp((center-lateral)/dimensions,lowUV,legalHighUV)' in edge
assert 'float screenConeTangent = 0.21255656f;' in formula
assert 'float legalRadius = 16.0f * pointScale;' in formula
assert 'return 0.25f * (a + b + c + d);' in formula
assert 'LGMinificationFootprint opticalFootprint=' in msl
assert 'opticalSample=localButtonMinifiedSample' in msl, 'existing primary AA path must remain'
assert 'LGMinificationFootprint environmentFootprint=' not in msl
assert generator.count('localButtonEdgeRadianceSample(')>=2
print(f'PASS: source-only checks; MSL SHA256={actual}; edge taps=4; primary AA retained')
