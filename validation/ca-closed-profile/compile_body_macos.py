from pathlib import Path
import sys,subprocess,json
R,O,SDK=map(Path,sys.argv[1:]);assert sys.platform=='darwin';O.mkdir(parents=True,exist_ok=True);records=[]
for arch in ['arm64','arm64e']:
 for macro in [0,1,2]:
  name=f'{arch}-ca-profile{macro}';out=O/(name+'.o')
  cmd=['xcrun','--sdk','iphoneos','clang++','-target',arch+'-apple-ios16.5','-isysroot',str(SDK),'-std=c++17','-fobjc-arc','-fblocks','-Werror=return-type','-Werror=objc-method-access','-Wno-deprecated-declarations','-DLG_CA_CLOSED_PROFILE_COMPILED='+str(macro),'-c',str(R/'LiquidAssBackboardd/Tweak.mm'),'-o',str(out)]
  p=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);(O/(name+'.log')).write_text(p.stdout);assert p.returncode==0,(name,p.stdout[-8000:])
  nm=subprocess.check_output(['xcrun','nm','--defined-only',str(out)],text=True);has='LGCAClosedProfileRuntime' in nm;assert has==(macro==1),('Default-off source path escaped',name)
  records.append({'name':name,'actualBodyCompiled':True,'newProfileSymbolsLinked':has,'oldSystemUniformABIBytes':208})
(O/'actual-ca-body-compile.json').write_text(json.dumps({'checks':records,'scope':'Actual isolated LiquidAssBackboardd/Tweak.mm Apple compile and symbols only; no daemon linking/install/runtime'},indent=2));print('PASS original real CA body actualcompile/symbol matrix',len(records))
