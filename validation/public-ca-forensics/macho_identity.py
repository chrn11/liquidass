from pathlib import Path
import struct,hashlib,uuid,json

def inspect(path):
 path=Path(path);b=path.read_bytes();magic,cpu,sub,kind,ncmds,cmdbytes,flags,_=struct.unpack_from('<8I',b)
 assert magic==0xfeedfacf and cpu==0x100000c and (sub&0xffffff)==2 and kind==6,'Not a real arm64e Mach-O dylib'
 assert 32+cmdbytes<=len(b);p=32;identity=None;segments=[];text=None
 for _ in range(ncmds):
  cmd,n=struct.unpack_from('<II',b,p);assert n>=8 and p+n<=32+cmdbytes
  if cmd==0x1b:identity=str(uuid.UUID(bytes=b[p+8:p+24])).upper()
  if cmd==0x19:
   name=b[p+8:p+24].split(b'\0')[0].decode();addr,vmsize,offset,size=struct.unpack_from('<4Q',b,p+24);count=struct.unpack_from('<I',b,p+64)[0]
   segments.append({'name':name,'vmaddr':addr,'vmsize':vmsize,'fileoff':offset,'filesize':size})
   for i in range(count):
    q=p+72+i*80;sect=b[q:q+16].split(b'\0')[0].decode();seg=b[q+16:q+32].split(b'\0')[0].decode();sa,ss=struct.unpack_from('<QQ',b,q+32);so=struct.unpack_from('<I',b,q+48)[0]
    if sect=='__text' and seg=='__TEXT':
     assert so+ss<=len(b);text={'vmaddr':sa,'fileoff':so,'bytes':ss,'sha256':hashlib.sha256(b[so:so+ss]).hexdigest()}
  p+=n
 assert identity and text and text['bytes']>100000,'Missing UUID or executable instructions (SDK stubs are not acceptable)'
 return {'file':path.name,'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest(),'cpu':'arm64e','cpuSubtypeRaw':sub,'MachOType':'MH_DYLIB','LC_UUID':identity,'text':text,'segments':segments}
if __name__=='__main__':
 import sys
 print(json.dumps(inspect(sys.argv[1]),indent=2))
