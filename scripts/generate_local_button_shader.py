#!/usr/bin/env python3
"""Rebuild the local read-only shader literal from frozen kShaderSrc + .inc."""
from pathlib import Path
import hashlib, re, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[1]
BACKBOARD=ROOT/'LiquidAssBackboardd/Tweak.mm'
SHARED=ROOT/'Shared'
EXPECTED='f21b394471fd9d3983502441852e3be0664eec7614a7bcd7652939077c06a72b'
text=BACKBOARD.read_text()
m=re.search(r'kShaderSrc\s*=\s*R"MSL\((.*?)\)MSL";',text,re.S)
if not m: raise SystemExit('frozen kShaderSrc raw MSL not found')
base=m.group(1)
marker='//__LG_BUTTON_OPTICS_FORMULA__'
if base.count(marker)!=1: raise SystemExit('shader marker count drift')
probe='#include "LGButtonOpticsShaderSource.h"\n#include <stdio.h>\nint main(void){fwrite(kLGButtonOpticsFormulaMSL,1,sizeof(kLGButtonOpticsFormulaMSL)-1,stdout);return 0;}\n'
with tempfile.TemporaryDirectory() as td:
    exe=Path(td)/'formula'
    subprocess.run(['clang','-std=c11','-x','c','-','-o',str(exe)],cwd=SHARED,input=probe,text=True,check=True)
    formula=subprocess.check_output([str(exe)],text=True)
source=('#define LG_BUTTON_OPTICS_COMPILED 1\n'+base.replace(marker,formula))
digest=hashlib.sha256(source.encode()).hexdigest()
if digest!=EXPECTED: raise SystemExit(f'candidate MSL identity drift: {digest}')
delim='LGLOCALMSL'
if f'){delim}"' in source: raise SystemExit('raw string delimiter collision')
out=SHARED/'LGLocalButtonShaderSource.h'
header=('/* Generated, read-only result of frozen kShaderSrc + existing .inc. */\n'
        '#pragma once\n#ifndef __cplusplus\n#error "local Metal source is consumed from Objective-C++ only"\n#endif\n'
        'static const char kLGLocalButtonCandidateMSL[] = R"'+delim+'('+source+')'+delim+'";\n'
        'static const char kLGLocalButtonCandidateMSLSHA256[] = "'+digest+'";\n')
out.write_text(header)
print(f'generated {out}; sha256={digest}; bytes={len(source.encode())}')
