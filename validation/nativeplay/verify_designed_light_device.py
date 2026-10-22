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
helper=(v/'LGDesignedLightGPUCapture.h').read_text()
primary=helper.index('if (!LGDLPrimaryStrengthIsOn(uniforms.fresnelGlareStrength))')
assert primary < helper.index('off=LGDLNewSharedTexture') < helper.index('encodedOff=LGDLEncodePass')
assert 'primaryDrawableUniformStrength' in helper and 'primaryPassUniformSHA256' in helper
assert 'FINAL_MANIFEST_WRITE_FAILED' in helper and 'PASS_ALL_FOUR_GPU_READBACKS_SAVED' in helper
assert 'filesSHA256' in helper and 'LGDLAwaitLedger(self.ledger' in helper
assert 'self.explicitOptIn,enabled,ownBundle,pipelineReady,_experimentCapture!=nil' in impl
assert impl.index('_experimentCapture=[LGDesignedLightCapture new]') < impl.index('_experimentalDesignedLightEnabled=YES')
assert 'LG_LOCAL_DESIGNED_LIGHT_EXPERIMENT == 1' in impl and 'LG_LOCAL_DESIGNED_LIGHT_EXPERIMENT == 1' in api
assert 'LGDLFixtureCaptureFinalizer' in api and 'LGDesignedLightCapture *capture=self.experimentCapture' in impl
probe=(v/'OwnedTouchRuntimeProbe.mm').read_text();aggregate=(v/'LocalRendererRuntimeProbe.mm').read_text()
assert probe.index('LGDLFixtureCaptureFinalizer captureFinalizer=') < probe.index('[self cleanupFixture];',probe.index('LGDLFixtureCaptureFinalizer captureFinalizer='))
assert 'FAIL_TOUCH_OR_CAPTURE_SUITE' in probe and 'L_four_auxiliary_GPU_captures_independent_of_touch_PASS' in aggregate
inputs=json.loads((v/'source-input-manifest.json').read_text())
assert inputs['expectedShaderSHA256']==inputs['expectedRuntimeShaderSHA256']==inputs['designedLightDeviceExperiment']['MSLSHA256']
assert inputs['carrierSelfCheckShaderSHA256']==sha(v/'carrier/main-runtime-candidate.metal')
exp=inputs['designedLightDeviceExperiment']
for key,name in [('rendererSHA256','Shared/LGLocalButtonMaterialView.mm'),('rendererHeaderSHA256','Shared/LGLocalButtonMaterialView.h'),('captureHelperSHA256','validation/nativeplay/LGDesignedLightGPUCapture.h'),('realUIKitFixtureSHA256','validation/nativeplay/OwnedTouchRuntimeProbe.mm')]:
    assert exp[key]==sha(root/name),('Active experiment fingerprint drift',key)
print('Hardened primary-input/effective-gate/capture-completion structure and frozen optical/source contracts: PASS; runtime separately tested')
