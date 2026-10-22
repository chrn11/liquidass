from pathlib import Path
import json,re,hashlib,sys
root=Path(sys.argv[1]);v=root/'validation/nativeplay';m=json.loads((v/'designed-light-frozen-contracts.json').read_text())
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
for name,digest in m.items():assert sha(root/name)==digest,('Optical/source contract unexpectedly changed',name)
s=(root/'Shared/LGLocalButtonShaderSource.h').read_text();b=re.search(r'R"LGLOCALMSL\((.*?)\)LGLOCALMSL";',s,re.S).group(1)
assert hashlib.sha256(b.encode()).hexdigest()=='1859d9436938cdbf51b4cb215b897ea175a9e3fddff7c6631e662d311af75740'
api=(root/'Shared/LGLocalButtonMaterialView.h').read_text();impl=(root/'Shared/LGLocalButtonMaterialView.mm').read_text()
assert 'LG_LOCAL_DESIGNED_LIGHT_EXPERIMENT' in api and 'experimentalDesignedLighting:(BOOL)enabled' in api
assert 'org.liquidass.native-play-lab' in impl and 'out->fresnelGlareStrength=1.0f' in impl
assert 'self.framebufferOnly=YES' in impl and 'self.framebufferOnly=NO' not in impl
assert 'experimentalDesignedLighting:YES' in (v/'OwnedTouchRuntimeProbe.mm').read_text()
assert (v/'LGDesignedLightGPUCapture.h').is_file()
assert 'LG_LOCAL_DESIGNED_LIGHT_EXPERIMENT' not in (root/'Makefile').read_text()
print('Experiment-only switch, exact 240B builder/100ms source contracts and pinned reviewed shader: PASS (structure only)')
