from pathlib import Path
import re,sys,tempfile,subprocess,shutil

def check(root):
 root=Path(root);header=(root/'Shared/LGCAClosedSourceAdmission.h').read_text();source=(root/'LiquidAssBackboardd/Tweak.mm').read_text()
 code=re.sub(r'/\*.*?\*/|//[^\n]*','',header,flags=re.S);compact=re.sub(r'\s+','',code)
 assert compact=='#pragmaonce#include<stdbool.h>staticinlineboolLGCAClosedProductionSourceAdmitted(void){returnfalse;}','Unintegrated producer source must stay denied; no bool/token/override input'
 needle='if (closedRequested && LGCAClosedProductionSourceAdmitted() &&\n        LGCAClosedProfileMayUse('
 assert source.count(needle)==1,'Exact production source guard is missing or ambiguous'
 start=source.index(needle);end=source.index('\n#endif',start);branch=source[start:end]
 assert branch.count('LGCAClosedRuntimeForDevice(device)')==1,'Runtime creation must be inside source-denied branch'
 assert branch.count('encodeAuditForSource:origTex command:cmdBuf')==1
 assert source.count('LGCAClosedRuntimeForDevice(device)')==1 and source.count('encodeAuditForSource:origTex command:cmdBuf')==1,'Unguarded alternative source path'
 assert source.index('#include "../Shared/LGCAClosedSourceAdmission.h"')<start

def mutation_tests(root):
 files=['Shared/LGCAClosedSourceAdmission.h','LiquidAssBackboardd/Tweak.mm'];tested=0
 for name,old,new in [('Shared/LGCAClosedSourceAdmission.h','return false;','return true;'),('LiquidAssBackboardd/Tweak.mm','LGCAClosedProductionSourceAdmitted() &&','true &&'),('Shared/LGCAClosedSourceAdmission.h','return false;','return (bool)1;')]:
  with tempfile.TemporaryDirectory(prefix='lgca-admission-negative-') as tmp:
   for n in files:
    p=Path(tmp)/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(Path(root)/n,p)
   p=Path(tmp)/name;s=p.read_text();assert s.count(old)==1;p.write_text(s.replace(old,new,1))
   rejected=False
   try:check(tmp)
   except AssertionError:rejected=True
   assert rejected,'Source promotion mutation was not rejected';tested+=1
 return tested
if __name__=='__main__':
 root=sys.argv[1];check(root)
 if '--mutations' in sys.argv:print('PASS source-admission negative mutations',mutation_tests(root))
 print('PASS real CA production entry denies unintegrated source before optional runtime creation; low-level shader tests are not producer proof')
