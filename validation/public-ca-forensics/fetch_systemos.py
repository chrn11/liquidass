from pathlib import Path
import io,urllib.request,time,json,plistlib,zipfile,hashlib,sys,os
V=Path(__file__).resolve().parent;E=json.loads((V/'expected.json').read_text());O=Path(sys.argv[1]);T=Path(sys.argv[2]);O.mkdir(parents=True,exist_ok=True);T.mkdir(parents=True,exist_ok=True)
assert sys.platform=='darwin','Public firmware image is processed only on authorized macOS CI, never on the phone'
class RemoteAppleIPSW(io.RawIOBase):
 def __init__(self):self.pos=0;self.total=0;self.requests=[]
 def readable(self):return True
 def seekable(self):return True
 def tell(self):return self.pos
 def seek(self,n,w=0):
  self.pos=n if w==0 else (self.pos+n if w==1 else E['archiveBytes']+n)
  assert 0<=self.pos<=E['archiveBytes'];return self.pos
 def read(self,n=-1):
  if n<0:n=E['archiveBytes']-self.pos
  n=min(n,E['archiveBytes']-self.pos)
  if not n:return b''
  assert n<=64*1024*1024 and self.total+n<=E['componentCompressedBytes']+64*1024*1024,'Remote range budget exceeded; fullIPSW forbidden'
  start=self.pos;end=start+n-1
  for attempt in range(3):
   try:
    req=urllib.request.Request(E['sourceURL'],headers={'Range':f'bytes={start}-{end}','Accept-Encoding':'identity','User-Agent':'Minis-authorized-public-CA-evidence'})
    with urllib.request.urlopen(req,timeout=120) as r:
     assert r.status==206 and r.headers.get('Content-Range')==f'bytes {start}-{end}/{E["archiveBytes"]}','Exact range required; no full restore fallback'
     b=r.read(n+1)
    assert len(b)==n;break
   except (OSError,TimeoutError):
    if attempt==2:raise
  self.pos+=len(b);self.total+=len(b);self.requests.append({'offset':start,'bytes':n});return b
r=RemoteAppleIPSW();m={};image=T/E['component'];h=hashlib.sha384();sha=hashlib.sha256();count=0
try:
 with zipfile.ZipFile(r) as z:
  manifestBytes=z.read('BuildManifest.plist');manifest=plistlib.loads(manifestBytes)
  assert hashlib.sha256(manifestBytes).hexdigest()==E['manifestSHA256'] and manifest['ProductBuildVersion']==E['build'] and manifest['ProductVersion']==E['version'] and manifest['SupportedProductTypes']==[E['device']]
  ids=[i for i in manifest['BuildIdentities'] if i['Info']['DeviceClass']==E['deviceClass']];assert ids
  for i in ids:
   c=i['Manifest']['Cryptex1,SystemOS'];assert c['Info']['Path']==E['component'] and c['Digest'].hex()==E['componentSHA384'] and c['Info']['HashMethod']=='sha2-384'
  entry=z.getinfo(E['component']);assert entry.file_size==E['componentBytes'] and entry.compress_size==E['componentCompressedBytes'] and entry.compress_type==8
  (O/'BuildManifest.plist').write_bytes(manifestBytes)
  with z.open(entry) as source,image.open('wb') as out:
   while True:
    b=source.read(16*1024*1024)
    if not b:break
    out.write(b);h.update(b);sha.update(b);count+=len(b)
    if count//(256*1024*1024)!=(count-len(b))//(256*1024*1024):print('PUBLIC_SYSTEMOS_UNPACKED_BYTES',count,flush=True)
  assert count==E['componentBytes'] and h.hexdigest()==E['componentSHA384'],'Official component Digest mismatch; no analysis of unverified image'
  with image.open('rb') as f:prefix=f.read(4096)
  assert prefix[32:36]==b'NXSB','Expected APFS container only'
  m={'status':'VERIFIED_APPLE_PUBLIC_COMPONENT','device':E['device'],'deviceClass':E['deviceClass'],'version':E['version'],'build':E['build'],'component':E['component'],'sourceURL':E['sourceURL'],'manifestSHA256':hashlib.sha256(manifestBytes).hexdigest(),'officialComponentSHA384':E['componentSHA384'],'actualComponentSHA384':h.hexdigest(),'actualComponentSHA256':sha.hexdigest(),'unpackedBytes':count,'zipCRC32':f'{entry.CRC:08x}','zipCRCCheckedByPython':True,'APFSHeaderNXSB':True,'publicRangeBytesDownloaded':r.total,'publicRangeRequestCount':len(r.requests),'wholeIPSWDownloaded':False,'deviceAccess':False}
  (T/'image-path.txt').write_text(str(image));print(json.dumps(m,indent=2),flush=True)
except Exception as error:
 m={'status':'FAILED_PUBLIC_COMPONENT_VERIFICATION','errorType':type(error).__name__,'detail':str(error),'bytesUnpacked':count,'publicRangeBytesDownloaded':r.total,'deviceAccess':False};raise
finally:
 (O/'component-provenance.json').write_text(json.dumps(m,indent=2))
