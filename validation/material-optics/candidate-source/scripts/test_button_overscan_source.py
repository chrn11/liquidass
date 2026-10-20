#!/usr/bin/env python3
"""Mechanical/numeric overscan contract checks; never compiles or renders pixels."""
from pathlib import Path
import hashlib, math, re
root=Path(__file__).resolve().parents[1]
contract=(root/'Shared/LGLocalButtonSourceContract.h').read_text()
uniforms=(root/'Shared/LGLocalButtonUniforms.h').read_text()
impl=(root/'Shared/LGLocalButtonMaterialView.mm').read_text()
shader_h=(root/'Shared/LGLocalButtonShaderSource.h').read_text()
metal=(root/'scripts/test_button_contact_metal.mm').read_text()
c_test=(root/'scripts/test_local_button_source_contract.c').read_text()
body=re.search(r'R"LGLOCALMSL\((.*?)\)LGLOCALMSL";',shader_h,re.S).group(1)
sha=hashlib.sha256(body.encode()).hexdigest()
assert sha=='a2b3e9e685f618b5b91fc57586d9777d41cbbecd8113bf250784923d5cba1975'
assert '#define LG_LOCAL_BUTTON_MAX_OVERSCAN_PADDING_POINTS 16.0' in contract
assert 'sourceOverscanEnabled' in contract and 'LGLocalSourceLayoutForContract' in contract
assert 'pads[i]<0.0' in contract and 'pads[i]>LG_LOCAL_BUTTON_MAX_OVERSCAN_PADDING_POINTS' in contract
assert 'sourceOverscanEnabled && fabs(pads[i])' not in contract
# Same-point-scale layout fixture: 62pt source, 44pt target, (8,6,10,12)pt pads.
source=(2.0,14.0,62.0,62.0); target=(10.0,20.0,44.0,44.0); scale=3.0
left=target[0]-source[0]; top=target[1]-source[1]
right=source[0]+source[2]-target[0]-target[2]
bottom=source[1]+source[3]-target[1]-target[3]
assert (left,top,right,bottom)==(8.0,6.0,10.0,12.0)
assert all(0<=v<=16 for v in (left,top,right,bottom))
assert (round(44*scale),round(44*scale))==(132,132)
assert (left*scale,top*scale)==(24,18)
# Point-to-pixel map: target-local UV maps into the larger immutable texture;
# it uses full-source half-texel clamps and never the target-sized UV as whole-texture UV.
sw=sh=62*scale; ox,oy=left*scale,top*scale
for uv in ((0.5/132,0.5/132),(0.5,0.5),(1-0.5/132,1-0.5/132)):
    px=(ox+uv[0]*132,oy+uv[1]*132)
    suv=(px[0]/sw,px[1]/sh)
    assert 0.5/sw<=suv[0]<1-0.5/sw and 0.5/sh<=suv[1]<1-0.5/sh
# The zero-padding path must return targetUV before any transform, preserving the
# prior source sample expression; the extended ABI is appended after byte 224.
assert 'if (u.buttonSourceOverscanEnabled <= 0.5f) return targetUV;' in body
assert 'offsetof(LGLocalButtonUniforms,buttonSourceTargetOriginPixels)==224' in uniforms
assert 'offsetof(LGLocalButtonUniforms,buttonSourceOverscanEnabled)==232' in uniforms
assert 'sizeof(LGLocalButtonUniforms)==240' in uniforms
assert 'legacyLength!=224u' in uniforms and 'memcpy(out,legacyBytes,224u)' in uniforms
assert body.count('src.sample(s,')==(
    body.count('src.sample(s, localButtonSourceUV(src, u,')+
    body.count('src.sample(s,localButtonSourceUV(src,u,'))
assert 'targetPosition>=u.resolution' in body and 'targetGid' in body
assert 'uint2 targetDimensions=max(uint2(u.resolution),uint2(1))' in body
assert 'LGButtonCandidateMaxDisplacement(g.sourceWidth,g.sourceHeight)' in uniforms
assert '(float)layout.targetPixelWidth' in uniforms and 'c->textureWidth' not in uniforms[uniforms.index('LGButtonCandidateBuildGeometry'):uniforms.index('const LGHostDefinition')]
assert 'buttonSourceTargetOriginPixels' in uniforms and 'state->touchX' in uniforms
assert 'self.drawableSize=CGSizeMake(targetPixelWidth,targetPixelHeight)' in impl
assert 'CGSizeMake(c.textureWidth,c.textureHeight)' not in impl
assert 'LGLocalSourceTargetPixelSize(&c,&targetWidth,&targetHeight)' in impl
assert 'outsideROIOnlySourceMutation' in metal and 'ROIInnerBytesIdentical' in metal
assert 'influenced<10' in metal and 'TestNoPadAgainstPrevious224' in metal
assert 'LGBOMapTargetUVToSource' in body
assert 'environmentUV=(capturePx+float2(optics.environmentOffsetX,optics.environmentOffsetY))/u.resolution;' in body
assert re.search(r'localButtonSourceUV\(src,\s*u,\s*environmentUV\)',body)
assert 'if (!anyPadding)' in contract and 'layout.targetPixelWidth=actualWidth;' in contract
assert 'layout.leftPaddingPoints>0.0' in uniforms
assert 'sourceOverscanEnabled=false' not in impl  # renderer never silently changes provider opt-in
for marker in ('LG_LOCAL_BUTTON_MAX_OVERSCAN_PADDING_POINTS','sourceOverscanEnabled=true',
               'LGLocalButtonPromoteContactABI224','buttonSourceTargetOriginPixels.x==24',
               'buttonContactCenter.x==.25f','LGLocalSourceBadGeometry'):
    assert marker in c_test, marker
print('overscan contract/layout/ROI UV/half-texel/no-pad ABI/source wiring: PASS')
print('Python numeric/source checks only; no CPU material render or compiler run.')
