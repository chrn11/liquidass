from pathlib import Path
import json,urllib.request,tarfile,platform,subprocess,plistlib,sys,hashlib,os,re,time,uuid,shutil
from macho_identity import inspect
V=Path(__file__).resolve().parent;E=json.loads((V/'expected.json').read_text());O=Path(sys.argv[1]);T=Path(sys.argv[2]);assert sys.platform=='darwin';O.mkdir(parents=True,exist_ok=True);logs=O/'logs';logs.mkdir(exist_ok=True);toolDir=T/'tool';toolDir.mkdir(exist_ok=True)
commands=[];mounts=[];device=None;archive=T/'ipsw-tool.tar.gz';summary={'status':'STARTED_PUBLIC_FIRMWARE_EXTRACTION','deviceAccess':False,'noProducerProofClaim':True}
def run(args,name,timeout=180,allowFailure=False):
 p=subprocess.run([str(x) for x in args],stdout=subprocess.PIPE,stderr=subprocess.PIPE,stdin=subprocess.DEVNULL,timeout=timeout)
 (logs/(name+'.stdout')).write_bytes(p.stdout);(logs/(name+'.stderr')).write_bytes(p.stderr);commands.append({'label':name,'command':[str(x) for x in args],'exitCode':p.returncode})
 if not allowFailure and p.returncode:raise RuntimeError(name+' failed; see exact stdout/stderr')
 return p
try:
 arch=platform.machine();assert arch in E['tools'];asset=E['tools'][arch];archive=T/'ipsw-tool.tar.gz'
 run(['curl','--fail','--location','--retry','2','--connect-timeout','20','--max-time','180',asset['url'],'-o',archive],'tool-download',220)
 assert archive.stat().st_size==asset['bytes'] and hashlib.sha256(archive.read_bytes()).hexdigest()==asset['sha256'],'Public tool digest mismatch'
 with tarfile.open(archive) as z:
  members=[m for m in z.getmembers() if m.isfile() and Path(m.name).name=='ipsw'];assert len(members)==1
  binary=toolDir/'ipsw';binary.write_bytes(z.extractfile(members[0]).read());binary.chmod(0o755)
 run([binary,'version'],'tool-version',30)
 image=Path((T/'image-path.txt').read_text());assert image.parent==T and image.name==E['component']
 p=run(['hdiutil','attach','-readonly','-nobrowse','-plist',image],'attach-readonly',180,True)
 if p.returncode:
  p=run(['hdiutil','attach','-readonly','-nobrowse','-imagekey','diskimage-class=CRawDiskImage','-plist',image],'attach-readonly-raw',180)
 attached=plistlib.loads(p.stdout);entities=attached.get('system-entities',[])
 mounts=[Path(x['mount-point']) for x in entities if x.get('mount-point')]
 devices=[x['dev-entry'] for x in entities if x.get('dev-entry')];device=next((s for s in devices if re.fullmatch('/dev/disk[0-9]+',s)),devices[0] if devices else None)
 assert mounts and device,'Readonly APFS did not mount'
 cacheFiles=[]
 for mount in mounts:
  p=run(['rg','--files','-uuu',mount],'mount-file-list-'+str(len(cacheFiles)),60)
  cacheFiles.extend(Path(n) for n in p.stdout.decode().splitlines() if 'dyld_shared_cache_arm64e' in Path(n).name)
 mains=[p for p in cacheFiles if p.name=='dyld_shared_cache_arm64e'];assert len(mains)==1,'Require exact single arm64e shared cache'
 cache=mains[0];layout=[{'name':p.name,'relativePath':str(p.relative_to(next(m for m in mounts if p.is_relative_to(m)))),'bytes':p.stat().st_size} for p in cacheFiles]
 with cache.open('rb') as f:header=f.read(4096)
 assert header[:16].startswith(b'dyld_v1') and b'arm64e' in header[:16]
 cacheIdentity={'magic':header[:16].decode('ascii').rstrip('\0 '),'cacheHeaderUUID':str(uuid.UUID(bytes=header[88:104])).upper(),'cacheHeaderFirst4096SHA256':hashlib.sha256(header).hexdigest(),'files':layout}
 (O/'cache-identity.json').write_text(json.dumps(cacheIdentity,indent=2))
 run([binary,'dyld','info',cache,'--json'],'cache-info',120,True)
 identities=[]
 for mode in ['raw','rebased']:
  folder=O/('extracted-'+mode);folder.mkdir(exist_ok=True)
  args=[binary,'dyld','extract',cache,E['imagePath'],'--output',folder]
  if mode=='rebased':args.append('--slide')
  run(args,'extract-quartzcore-'+mode,300)
  file=folder/'QuartzCore';ident=inspect(file);ident['extractionMode']=mode;identities.append(ident)
  run(['xcrun','dwarfdump','--uuid',file],'uuid-'+mode,60)
  run(['xcrun','nm','-nm',file],'symbols-'+mode,120,True)
  run(['xcrun','otool','-l',file],'load-commands-'+mode,60)
 assert identities[0]['LC_UUID']==identities[1]['LC_UUID'] and identities[0]['text']['sha256']==identities[1]['text']['sha256'],'Extracted normalization changed executable instructions'
 paths=[Path(p) for p in subprocess.check_output(['rg','--files','-uuu',str(O)],text=True).splitlines()]
 allbytes=sum(p.stat().st_size for p in paths);assert allbytes< E['budget']['artifactMaxBytes']-1024*1024,'Evidence would exceed authorized64MiB output cap'
 summary={'status':'EXACT_PUBLIC_BUILD_QUARTZCORE_MACHINE_CODE_ACQUIRED','sourceURL':E['sourceURL'],'targetDevice':E['device'],'version':E['version'],'build':E['build'],'deviceClass':E['deviceClass'],'officialComponentDigestVerified':True,'tool':{'tag':E['toolTag'],'archiveSHA256':asset['sha256'],'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest()},'cache':cacheIdentity,'quartzCoreImages':identities,'sameTextBytesAcrossExportModes':True,'artifactBytesBeforeReceipt':allbytes,'actualLoadedDeviceUUIDMatched':'NOT_OBSERVED; no process/memory/device access','producerEventLeaseOrColorContractProven':False,'deviceAccess':False,'originalTaskCompleted':False}
except Exception as error:
 summary.update({'status':'PUBLIC_EXTRACTION_FAILED','errorType':type(error).__name__,'detail':str(error)})
 raise
finally:
 if device:
  try:run(['hdiutil','detach',device],'detach-readonly',90,True)
  except Exception as error:summary['detachIssue']=str(error)
 (O/'commands.json').write_text(json.dumps(commands,indent=2));(O/'public-extraction-summary.json').write_text(json.dumps(summary,indent=2))
 # Never retain the whole Apple component, full cache, or downloaded utility in artifact.
 image=T/E['component']
 if image.exists():image.unlink()
 if archive.exists():archive.unlink()
 print(json.dumps(summary,indent=2),flush=True)
