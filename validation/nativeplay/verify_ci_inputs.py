from pathlib import Path
import json,sys,hashlib,plistlib
root=Path(sys.argv[1]);sdk=Path(sys.argv[2]);m=json.loads((root/'validation/nativeplay/source-input-manifest.json').read_text())
assert sys.platform=='darwin','macOS/Xcode only'
for name,h in m['inputSHA256'].items():
 p=root/name
 assert p.is_file() and hashlib.sha256(p.read_bytes()).hexdigest()==h,('Frozen CI input differs',name)
settings=plistlib.loads((sdk/'SDKSettings.plist').read_bytes());assert str(settings.get('Version'))=='16.4',settings.get('Version')
assert m['buildBundle']=='org.liquidass.native-play-lab' and m['buildNumber']=='20'
print('Frozen source input verified:',len(m['inputSHA256']),'files; SDK16.5 path / metadata16.4; no closed reference or device data.')
