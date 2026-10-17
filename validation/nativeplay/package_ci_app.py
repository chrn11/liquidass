from pathlib import Path
import sys,struct,hashlib,json,plistlib,zipfile,os
root,out,sdk=map(Path,sys.argv[1:]);app=out/'NativePlayLab.app';c=root/'validation/nativeplay/carrier';sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
assert sys.platform=='darwin','Reject Linux packaging'
raw=(app/'NativePlayLab').read_bytes();h=struct.unpack_from('<8I',raw,0)
assert h[0]==0xfeedfacf and h[1]==0x100000c and h[2]&0xffffff==0 and h[3]==2,'Wrong real architecture or file type'
pos=32;commands=[]
for _ in range(h[4]):
 cmd,size=struct.unpack_from('<II',raw,pos);assert size>=8 and pos+size<=32+h[5];commands.append(cmd);pos+=size
assert 0x1d not in commands,'Unexpected signature load command'
for p in c.iterdir():
 if p.is_file() and p.suffix in ['.plist','.json','.png','.metal','.h']:(app/p.name).write_bytes(p.read_bytes())
info=plistlib.loads((app/'Info.plist').read_bytes());assert info['CFBundleIdentifier']=='org.liquidass.native-play-lab';info['CFBundleVersion']=json.loads((root/'validation/nativeplay/source-input-manifest.json').read_text())['buildNumber'];info['CFBundleShortVersionString']='1.3';(app/'Info.plist').write_bytes(plistlib.dumps(info,fmt=plistlib.FMT_BINARY,sort_keys=False))
manifest=json.loads((app/'manifest.json').read_text());manifest.setdefault('app',{}).update({'bundleIdentifier':'org.liquidass.native-play-lab','candidateBuild':int(info['CFBundleVersion']),'version':'1.3','scope':'same existing App, self-check only, macOS Actions'})
manifest.setdefault('source',{}).update({'nativePlayLensSHA256':sha(c/'PlayLens.metal'),'nativeControllerSHA256':sha(c/'NativePlayLabViewController.m'),'nativeMaterialSharedSHA256':sha(c/'PlayMaterialShared.h')})
manifest.setdefault('resources',{})['InputBotanical.png']=sha(c/'InputBotanical.png');(app/'manifest.json').write_text(json.dumps(manifest,indent=2))
files={str(p.relative_to(app)):sha(p) for p in app.iterdir() if p.is_file()};exe=app/'NativePlayLab';exe.chmod(0o755)
ipa=out/('NativePlayLab-local-renderer-build'+info['CFBundleVersion']+'-UNSIGNED.ipa')
with zipfile.ZipFile(ipa,'w',zipfile.ZIP_DEFLATED) as z:
 for p in app.iterdir():
  if p.is_file():z.write(p,'Payload/NativePlayLab.app/'+p.name)
with zipfile.ZipFile(ipa) as z:assert z.testzip() is None
provenance={'scope':'Minimal existing-App class validation only; not complete LiquidAss package or visual acceptance','repository':os.environ.get('GITHUB_REPOSITORY'),'commit':os.environ.get('GITHUB_SHA'),'runID':os.environ.get('GITHUB_RUN_ID'),'runner':'macOS / Apple xcrun clang and Apple linker','SDKPath':str(sdk),'SDKMetadata':plistlib.loads((sdk/'SDKSettings.plist').read_bytes()).get('Version'),'bundleID':info['CFBundleIdentifier'],'build':info['CFBundleVersion'],'realCpuType':h[1],'realCpuSubtype':h[2],'architecture':'arm64','signature':'ABSENT, no LC_CODE_SIGNATURE','ipa':ipa.name,'ipaSHA256':sha(ipa),'bundleFilesSHA256':files,'compiledSourcesSHA256':{'carrier':sha(c/'NativePlayLabViewController.m'),'probe':sha(root/'validation/nativeplay/LocalRendererRuntimeProbe.mm'),'actualLocalClass':sha(root/'Shared/LGLocalButtonMaterialView.mm'),'actualOwnedProvider':sha(root/'Shared/LGAppOwnedButtonSourceProvider.mm'),'ownedSourceProbe':sha(root/'validation/nativeplay/AppOwnedBackgroundRuntimeProbe.mm'),'actualUIKitTouchFixture':sha(root/'validation/nativeplay/OwnedTouchRuntimeProbe.mm')},'actualRuntimeClass':'NOT_RUN','systemSourceProvider':'NOT_IMPLEMENTED','installationPreferencesInjectionRestart':'NOT_PERFORMED'}
(out/'build16-ci-manifest.json').write_text(json.dumps(provenance,indent=2));print(json.dumps({k:v for k,v in provenance.items() if k in ['commit','runID','ipa','ipaSHA256','architecture','signature','actualRuntimeClass']},indent=2))
