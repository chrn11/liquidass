#!/usr/bin/env python3
"""Rebuild local MSL from frozen kShaderSrc + the shared .inc DSL."""
from pathlib import Path
import argparse, hashlib, re

ROOT=Path(__file__).resolve().parents[1]
BACKBOARD=ROOT/'LiquidAssBackboardd/Tweak.mm'
SHARED=ROOT/'Shared'
MARKER='//__LG_BUTTON_OPTICS_FORMULA__'
CONTACT_FIELDS=('    float2 buttonContactCenter;\n'
                '    float buttonContactPressure;\n'
                '    float buttonContactEnabled;\n')


def split_top(text):
    parts=[]; start=0; depth=0
    for i,ch in enumerate(text):
        if ch=='(': depth+=1
        elif ch==')': depth-=1
        elif ch==',' and depth==0:
            parts.append(text[start:i].strip()); start=i+1
    parts.append(text[start:].strip())
    return parts


def expand_formula(path):
    out=[]
    for number,line in enumerate(path.read_text().splitlines(),1):
        s=line.strip()
        if not s or s.startswith('/*') or s.startswith('*') or s.startswith('*/'):
            continue
        if s.startswith('LGBO_STRUCT_BEGIN('):
            out.append('struct '+s[len('LGBO_STRUCT_BEGIN('):-1]+' {\n')
        elif s.startswith('LGBO_FIELD('):
            p=split_top(s[len('LGBO_FIELD('):-1]);
            if len(p)!=2: raise SystemExit(f'bad FIELD DSL line {number}')
            out.append(p[0]+' '+p[1]+';\n')
        elif s.startswith('LGBO_STRUCT_END('): out.append('};\n')
        elif s.startswith('LGBO_FUNCTION_BEGIN('):
            p=split_top(s[len('LGBO_FUNCTION_BEGIN('):-1]);
            if len(p)!=3: raise SystemExit(f'bad FUNCTION DSL line {number}')
            out.append(f'{p[0]} {p[1]}{p[2]} {{\n')
        elif s.startswith('LGBO_STMT('): out.append(s[len('LGBO_STMT('):-1]+'\n')
        elif s=='LGBO_FUNCTION_END': out.append('}\n')
        else: raise SystemExit(f'unknown formula DSL at line {number}: {s[:80]}')
    return ''.join(out)


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--msl-out',type=Path,help='also write exact candidate MSL for macOS Metal compile')
    args=ap.parse_args()
    text=BACKBOARD.read_text()
    m=re.search(r'kShaderSrc\s*=\s*R"MSL\((.*?)\)MSL";',text,re.S)
    if not m: raise SystemExit('frozen kShaderSrc raw MSL not found')
    base=m.group(1)
    if base.count(MARKER)!=1: raise SystemExit('raw shader formula marker must occur exactly once')
    call='LGButtonOpticsResult optics = LGButtonOpticsEvaluate('
    if base.count(call)!=1 or base.index(MARKER)>=base.index(call):
        raise SystemExit('raw marker/candidate call order or count drift')
    old_field='    float buttonCandidateRendererScale;\n'
    if base.count(old_field)!=1: raise SystemExit('raw Uniforms ABI anchor drift')
    base=base.replace(old_field,old_field+CONTACT_FIELDS,1)
    base=base.replace(call,'LGButtonOpticsResult optics = LGButtonOpticsEvaluateWithContact(',1)
    old_tail='u.buttonCandidatePointScale, u.buttonCandidateRendererScale, true);'
    new_tail=('u.buttonCandidatePointScale, u.buttonCandidateRendererScale, true,\n'
              '            u.buttonContactEnabled > 0.5f, u.buttonContactCenter.x,\n'
              '            u.buttonContactCenter.y, u.buttonContactPressure);')
    if base.count(old_tail)!=1: raise SystemExit('raw candidate call argument anchor drift')
    base=base.replace(old_tail,new_tail,1)
    formula=expand_formula(SHARED/'LGButtonOpticsFormula.inc')
    source='#define LG_BUTTON_OPTICS_COMPILED 1\n'+base.replace(MARKER,formula)
    definition='LGButtonOpticsResult LGButtonOpticsEvaluateWithContact('
    actual_call='LGButtonOpticsResult optics = LGButtonOpticsEvaluateWithContact('
    if source.count(definition)!=1 or source.count(actual_call)!=1:
        raise SystemExit('contact function definition/call marker count drift')
    if source.index(definition)>=source.index(actual_call):
        raise SystemExit('contact call precedes shared formula definition')
    if source.count('float2 buttonContactCenter;')!=1 or source.count('float buttonContactPressure;')!=1 or source.count('float buttonContactEnabled;')!=1:
        raise SystemExit('generated MSL contact ABI field count drift')
    if ')LGLOCALMSL"' in source: raise SystemExit('raw string delimiter collision')
    digest=hashlib.sha256(source.encode()).hexdigest()
    header=('/* Generated: frozen LiquidAss kShaderSrc + shared formula DSL. */\n'
            '#pragma once\n#ifndef __cplusplus\n#error "local Metal source is consumed from Objective-C++ only"\n#endif\n'
            'static const char kLGLocalButtonCandidateMSL[] = R"LGLOCALMSL('+source+')LGLOCALMSL";\n'
            'static const char kLGLocalButtonCandidateMSLSHA256[] = "'+digest+'";\n')
    out=SHARED/'LGLocalButtonShaderSource.h'
    out.write_text(header)
    if args.msl_out:
        args.msl_out.parent.mkdir(parents=True,exist_ok=True)
        args.msl_out.write_text(source)
    print(f'generated {out}; sha256={digest}; bytes={len(source.encode())}')
    if args.msl_out: print(f'wrote raw MSL {args.msl_out}')

if __name__=='__main__': main()
