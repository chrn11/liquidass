from pathlib import Path
import sys,subprocess,os,json
assert sys.platform=='darwin','Actual Apple compile matrix only'
R,O,SDK=map(Path,sys.argv[1:]);O.mkdir(parents=True,exist_ok=True);checks=[]
for arch in ['arm64','arm64e']:
 for exp in [0,1,2]:
  for gate in [0,1]:
   name=f'{arch}-experiment{exp}-renderer{gate}';obj=O/(name+'.o')
   cmd=['xcrun','--sdk','iphoneos','clang++','-target',arch+'-apple-ios16.5','-isysroot',str(SDK),'-miphoneos-version-min=16.5','-fobjc-arc','-fblocks','-std=c++17','-Werror=objc-method-access','-DLG_LOCAL_BUTTON_RENDERER_COMPILED='+str(gate),'-DLG_LOCAL_DESIGNED_LIGHT_EXPERIMENT='+str(exp),'-I'+str(R/'Shared'),'-I'+str(R/'validation/nativeplay'),'-c',str(R/'Shared/LGLocalButtonMaterialView.mm'),'-o',str(obj)]
   p=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);(O/(name+'.log')).write_text(p.stdout);assert p.returncode==0,(name,p.stdout[-4000:])
   nm=subprocess.check_output(['xcrun','nm','--defined-only',str(obj)],text=True)
   has='experimentalDesignedLighting:' in nm and 'LGDesignedLightCapture' in nm
   assert has==(exp==1),('Experiment symbols escaped exact macro',name)
   checks.append({'name':name,'compiled':True,'experimentalSymbolsLinked':has,'policySeparatelyRequiresEffectiveRendererGate':True})
(O/'matrix.json').write_text(json.dumps({'checks':checks,'runtime':'NOT_RUN; actual per-macro Objective-C++ compiler/symbol checks, not UIKit execution'},indent=2));print('PASS actual Apple compile/symbol matrix',len(checks),'variants; no runtime inferred')
