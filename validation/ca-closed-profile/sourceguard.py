from pathlib import Path
import sys,json,hashlib,re,importlib.util,subprocess,tempfile
R=Path(sys.argv[1]);V=R/'validation/ca-closed-profile';M=json.loads((V/'input-manifest.json').read_text());sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
for n,h in M['inputSHA256'].items():assert sha(R/n)==h,('Frozen build input changed',n)
b=(V/'frozen149/Tweak.mm').read_text();s=(R/'LiquidAssBackboardd/Tweak.mm').read_text()
def raw(t):return re.search(r'kShaderSrc\s*=\s*R"MSL\((.*?)\)MSL";',t,re.S).group(1)
assert raw(b)==raw(s),'Original runtime MSL bytes changed'
def uniforms(t):return re.search(r'typedef struct \{(.*?)\} LGUniforms;',t,re.S).group(0)
assert uniforms(b)==uniforms(s),'Original208B system ABI changed'
assert 'sizeof(lu) atIndex:0' in s and 'closedAudit.buffer offset:0 atIndex:1' in s
assert 'closedRequested && LGCAClosedProfileMayUse(' in s and 'lu.buttonCandidate==1.0f' in s
assert 'g_caClosedProfileRequested{false}' in s and 'g_caDesignedLightRequested{false}' in s
assert 'LG_CA_CLOSED_PROFILE ?= 0' in (R/'LiquidAssBackboardd/Makefile').read_text()
assert sha(R/'Shared/LGButtonOpticsFormula.inc')==M['baselineFormulaSHA256']
for n,h in M['profileMathSHA256'].items():assert sha(V/'pinned-local-math'/n)==h
h=(R/'Shared/LGCAClosedProfileShaderSource.h').read_text();metal=re.search(r'R"LGCA_PROF\((.*?)\)LGCA_PROF"',h,re.S).group(1);old=re.search(r'R"LGCA_BASE\((.*?)\)LGCA_BASE"',h,re.S).group(1)
assert metal.startswith(old) and metal.count('struct Uniforms {')==1
assert hashlib.sha256(metal.encode()).hexdigest()==M['profileMSLSHA256']
assert hashlib.sha256(old.encode()).hexdigest()==M['baselineMSLSHA256']
runtime=(R/'Shared/LGCAClosedProfileRuntime.h').read_text()
for token in ['source.mipmapLevelCount!=1','source.parentTexture','source.buffer','source.heap','IOSurfaceGetID(a)==IOSurfaceGetID(b)','MTLResourceHazardTrackingModeTracked','selected.buffer.contents=0u','self.finalizePipeline','slot.generation++','retainedSlot.generation==generation','self.slots','newBufferWithLength:sizeof(uint32_t)']:
 assert token in runtime,token
assert runtime.index('[audit endEncoding]')<runtime.index('id<MTLComputeCommandEncoder> finalize=')<runtime.index('[finalize endEncoding]')
assert 'waitUntilCompleted' not in runtime and '[command commit]' not in runtime and 'getBytes:' not in runtime
assert 'atomic_load_explicit(auditWord,memory_order_relaxed)!=0x4c474341u' in metal
assert 'observed==expected' in metal and 'atomic_fetch_add_explicit(auditWord,1u' in metal
assert 'true,false,0.5f,0.5f,0.0f' in metal
assert 'level(0.0f)' in metal and 'LGCA_BOAnalyzeMinificationFootprint' in metal
# Exact generator reproduction occurs only in a disposable directory.
with tempfile.TemporaryDirectory(prefix='lg-ca-generator-') as temp:
 subprocess.run([sys.executable,str(V/'generate_ca_closed_shader.py'),'--baseline',str(V/'frozen149/Tweak.mm'),'--baseline-dsl',str(V/'frozen149/LGButtonOpticsFormula.inc'),'--profile-shared',str(V/'pinned-local-math'),'--profile-generator',str(V/'pinned-local-math/generate_local_button_shader.py'),'--out-dir',temp],check=True,stdout=subprocess.DEVNULL)
 assert sha(Path(temp)/'LGCAClosedProfileShaderSource.h')==sha(R/'Shared/LGCAClosedProfileShaderSource.h')
print('PASS exact old CA shader/208B ABI retained; sealed175 no-contact math, positive audit token and generator reproduction; source checks only')
