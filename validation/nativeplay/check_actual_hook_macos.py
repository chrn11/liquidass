#!/usr/bin/env python3
"""Apple-only focused validation of the original Hook and local adapter.
No local/Linux fallback; this does not link, install or enable a system tweak.
"""
from pathlib import Path
import sys,os,json,subprocess,tempfile
if sys.platform!='darwin':raise SystemExit('Refusing: compile only on GitHub Actions macOS')
R=Path(__file__).resolve().parents[2];T=Path(os.environ['THEOS']);SDK=Path(os.environ['SDK'])
CC=subprocess.check_output(['xcrun','--sdk','iphoneos','--find','clang'],text=True).strip()
CXX=subprocess.check_output(['xcrun','--sdk','iphoneos','--find','clang++'],text=True).strip()
results=[]
with tempfile.TemporaryDirectory(prefix='liquidass-real-hook-sdk-') as tmp:
 generated=Path(tmp)/'Controls.m'
 with generated.open('w') as f:
  subprocess.run(['perl',str(T/'vendor/logos/bin/logos.pl'),'-c','generator=libhooker',str(R/'Hooks/Controls.x')],stdout=f,check=True)
 for arch in ['arm64','arm64e']:
  for enabled in [0,1]:
   args=['-fsyntax-only','-ferror-limit=12','-fobjc-arc','-fblocks','-Werror=objc-method-access','-Werror=return-type','-Werror=protocol','-target',arch+'-apple-ios16.5','-isysroot',str(SDK),'-DLG_LOCAL_BUTTON_RENDERER_COMPILED='+str(enabled)]
   for p in [T/'include',T/'include/iphone',T/'vendor/include',R/'Shared']:args+=['-I',str(p)]
   for name,path,cxx in [('ActualControls',generated,False),('LocalRenderer',R/'Shared/LGLocalButtonMaterialView.mm',True),('AppOwnedProvider',R/'Shared/LGAppOwnedButtonSourceProvider.mm',True)]:
    command=[CXX if cxx else CC,*args,*(['-std=c++17','-x','objective-c++'] if cxx else ['-x','objective-c']),str(path)]
    subprocess.run(command,check=True);results.append({'source':name,'architecture':arch,'compiledGate':enabled,'pass':True})
    print('PASS actual original Hook/local/provider Apple SDK',name,arch,enabled,flush=True)
D=R/'ci-artifacts/local-renderer-hardening-build30';D.mkdir(parents=True,exist_ok=True)
(D/'actual-hook-sdk-validation.json').write_text(json.dumps({'scope':'Apple macOS focused syntax validation of real Hooks, not complete tweak linking or live Settings enablement','checks':results},indent=2))
