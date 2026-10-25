from pathlib import Path
import subprocess,sys,json,os
O=Path(sys.argv[1]);E=json.loads(Path(sys.argv[2]).read_text());O.mkdir(parents=True,exist_ok=True)
def files():
 p=subprocess.run(['rg','--files','-uuu',str(O)],text=True,capture_output=True);assert p.returncode in [0,1]
 return [Path(n) for n in p.stdout.splitlines()]
cap=E['budget']['artifactMaxBytes'];paths=files();before=sum(p.stat().st_size for p in paths);removed=[]
# Prefer the raw source image and identity receipts. Delete only redundant
# normalized copies/oversized diagnostic text if needed; never fabricate data.
priority=sorted(paths,key=lambda p:(0 if 'extracted-rebased' in p.parts else 1 if p.suffix in ['.stdout','.stderr'] else 2,-p.stat().st_size))
size=before
for p in priority:
 if size<cap-128*1024:break
 if p.name.endswith('.json') or p.name=='BuildManifest.plist':continue
 n=p.stat().st_size;removed.append({'path':str(p.relative_to(O)),'bytes':n});p.unlink();size-=n
assert size<cap-128*1024,'Cannot fit authorized evidence budget'
r={'authorizedOutputMaxBytes':cap,'actualBeforePruning':before,'actualAfterPruningBeforeReceipt':size,'removedRedundantOrOversizeFiles':removed,'noFullIPSWSystemOSOrCacheInOutput':not any(p.suffix=='.dmg' or p.name.startswith('dyld_shared_cache') for p in files())};assert r['noFullIPSWSystemOSOrCacheInOutput'];(O/'output-budget.json').write_text(json.dumps(r,indent=2));print(json.dumps(r,indent=2))
