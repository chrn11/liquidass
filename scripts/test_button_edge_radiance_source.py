#!/usr/bin/env python3
"""Source structure only. Mac C/Metal/real pixel gates are required separately."""
from pathlib import Path
import json,re,hashlib,subprocess,tempfile,sys
R=Path(__file__).resolve().parents[1]
def msl(root):return re.search(r'R"LGLOCALMSL\((.*?)\)LGLOCALMSL";', (root/'Shared/LGLocalButtonShaderSource.h').read_text(),re.S).group(1)
s=msl(R);pin=json.loads((R/'docs/edge-radiance-candidate-manifest.json').read_text());assert hashlib.sha256(s.encode()).hexdigest()==pin['candidateFingerprints']['generatedCandidateMSLSHA256']
f=(R/'Shared/LGButtonOpticsFormula.inc').read_text();g=(R/'scripts/generate_local_button_shader.py').read_text()
assert 'struct LGBOEdgeExteriorPatch' in s and 'LGBOBuildEdgeExteriorPatch(targetPoint.x,targetPoint.y' in s
helper=s.split('float4 localButtonEdgeRadianceSample(',1)[1].split('\n}',1)[0]
assert helper.count('src.sample(s,')==4
assert 'LGBOAverageFourRadianceSamples(a.r,b.r,c.r,d.r)' in helper
assert 'if (any(p0<lowUV)' in helper and 'thread bool &sourceValid' in helper
assert 'clamp((origin+' not in helper and 'sourceValid=false;' in helper
assert 'sourceValid=true;' in helper
assert 'if (!edgeSourceValid) optics.environmentWeight=0.0f;' in s
assert 'if (environmentWeight <= 0.0f) return opticalSample;' in s
assert 'u.buttonSourceOverscanEnabled > 0.5f && optics.environmentWeight > 0.0f' in s
assert 'float weight = edgeBand * schlick * thicknessCoverage;' in s
assert 'LGBOClamp(-q.signedDistance / lipWidth, 0.0f, 1.0f)' in f
assert 'LGBOClamp(q.height / lipWidth, 0.0f, 1.0f)' in f
assert 'float lipWidth = LGBOMin(pointScale * 1.5f, depthRadius);' in f
assert 'lipCapHeight * ((3.0f - lipQ) * lipU2 + (lipQ - 2.0f) * lipU3)' in f
assert 'heightDerivative = (lipCapHeight / lipWidth)' in f
assert 'if (depth < lipWidth)' in f
assert s.count('localButtonEvaluateAt(float2(px.x')==4
assert 'kernelXX' in s and 'support*support-1.0f' in s
assert 'opticalSample=localButtonMinifiedSample(src,s,localButtonSourceUV(src,u,opticalUV),opticalFootprint)' in s
assert all(x not in g for x in ['drawViewHierarchy','write('+'texture','MIPFilterLinear'])
# A comma at the top level is another preprocessor macro argument, even
# though the generated C-like MSL string could happen to accept it.
for n in ['LGButtonOpticsFormula.inc','LGEdgeExteriorPatch.inc','LGLocalMinification.inc']:
 for number,line in enumerate((R/'Shared'/n).read_text().splitlines(),1):
  if not line.strip().startswith('LGBO_STMT('):continue
  args=line.strip()[len('LGBO_STMT('):-1];depth=0
  for ch in args:
   if ch=='(':depth+=1
   elif ch==')':depth-=1
   elif ch==',' and depth==0:raise AssertionError((n,number,'Extra macro argument; split declaration'))
# Re-generation must reproduce exactly the submitted raw MSL, no compiler used.
with tempfile.TemporaryDirectory(prefix='edge-source-') as t:
 out=Path(t)/'candidate.metal';subprocess.run([sys.executable,str(R/'scripts/generate_local_button_shader.py'),'--msl-out',str(out)],check=True,stdout=subprocess.PIPE,text=True)
 assert out.read_text()==s
print('PASS exterior shared geometry/actual capture bounds/zero branch/contour continuity source contract; not C/MSL or GPU runtime evidence')
