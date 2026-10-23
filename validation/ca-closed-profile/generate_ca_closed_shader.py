#!/usr/bin/env python3
"""Build a CA-audited closed-material Metal library without editing product sources.

The output is the exact baseline-149 Metal source (compile prefix + frozen raw
kShaderSrc with only its original DSL marker expanded), followed byte-for-byte
by a separately named CA closed-profile fragment and alpha-audit kernel.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import sys

WORKSPACE = Path('/var/minis/workspace/liquidass-ca-closed-kernel').resolve()
BASELINE = Path('/var/minis/shared/liquidass-owned-refresh-main-429125e9-cf4f-4673-98f8-d71c40549c3d/LiquidAssBackboardd/Tweak.mm')
BASELINE_DSL = Path('/var/minis/shared/liquidass-owned-refresh-main-429125e9-cf4f-4673-98f8-d71c40549c3d/Shared/LGButtonOpticsFormula.inc')
PROFILE_SHARED = Path('/var/minis/shared/liquidass-designed-light-3d924672-a5a2-4036-9dda-d557c72fd23d/Shared')
PROFILE_GENERATOR = Path('/var/minis/shared/liquidass-designed-light-3d924672-a5a2-4036-9dda-d557c72fd23d/scripts/generate_local_button_shader.py')
MARKER = b'//__LG_BUTTON_OPTICS_FORMULA__'
COMPILE_PREFIX = b'#define LG_BUTTON_OPTICS_COMPILED 1\n'

# These two helper bodies are the no-overscan/no-environment specializations
# of the 175 generator's MINIFICATION_MSL_HELPER and DESIGNED_LIGHT_MSL_HELPER.
# Formula math stays in the three shared .inc DSLs; only resource mapping is
# specialized to q.sampleUV and the existing origTex.
MINIFICATION_HELPER = r'''
float2 LGCA_SourceTexels(LGCA_ButtonOpticsResult q,
                         texture2d<float, access::sample> source) {
    return float2(q.sampleU,q.sampleV) *
           float2((float)source.get_width(),(float)source.get_height());
}

LGCA_ButtonOpticsResult LGCA_EvaluateAt(float2 point, constant Uniforms &u) {
    return LGCA_ButtonOpticsEvaluateWithContact(
        point.x,point.y,u.resolution.x,u.resolution.y,
        u.buttonCandidateCenter.x,u.buttonCandidateCenter.y,
        u.buttonCandidateCornerRadius,u.bezelWidth,
        u.glassThickness,u.refractiveIndex,u.refractionScale,
        u.buttonCandidateMaxOffset,u.buttonCandidatePointScale,
        u.buttonCandidateRendererScale,true,false,0.5f,0.5f,0.0f);
}

float4 LGCA_MinifiedSample(texture2d<float, access::sample> source,
                           sampler s, float2 sourceUV,
                           LGCA_MinificationFootprint footprint) {
    float2 dimensions=float2((float)source.get_width(),(float)source.get_height());
    float2 halfTexel=0.5f/dimensions;
    float2 highUV=1.0f-halfTexel;
    if (footprint.tapCount!=4)
        return source.sample(s,sourceUV,level(0.0f));
    float2 deltaA=float2(3.0f*footprint.kernelXX+footprint.kernelXY,
                         3.0f*footprint.kernelXY+footprint.kernelYY)/dimensions;
    float2 deltaB=float2(footprint.kernelXX-3.0f*footprint.kernelXY,
                         footprint.kernelXY-3.0f*footprint.kernelYY)/dimensions;
    float2 a=clamp(sourceUV-deltaA,halfTexel,highUV);
    float2 b=clamp(sourceUV-deltaB,halfTexel,highUV);
    float2 c=clamp(sourceUV+deltaB,halfTexel,highUV);
    float2 e=clamp(sourceUV+deltaA,halfTexel,highUV);
    return 0.25f*(source.sample(s,a,level(0.0f))+
                  source.sample(s,b,level(0.0f))+
                  source.sample(s,c,level(0.0f))+
                  source.sample(s,e,level(0.0f)));
}
'''

DESIGNED_LIGHT_HELPER = r'''
float4 LGCA_DesignedLighting(float4 base, LGCA_ButtonOpticsResult q,
                             LGCA_ButtonOpticsResult mx, LGCA_ButtonOpticsResult px,
                             LGCA_ButtonOpticsResult my, LGCA_ButtonOpticsResult py,
                             constant Uniforms &u) {
    if (!isfinite(u.fresnelGlareStrength) || u.fresnelGlareStrength<=0.0f)
        return base;
    float w=0.5f*LGCA_DesignedSoftboxCoefficient(
        q,u.refractiveIndex,u.buttonCandidatePointScale,u.fresnelGlareStrength);
    w+=0.125f*LGCA_DesignedSoftboxCoefficient(
        mx,u.refractiveIndex,u.buttonCandidatePointScale,u.fresnelGlareStrength);
    w+=0.125f*LGCA_DesignedSoftboxCoefficient(
        px,u.refractiveIndex,u.buttonCandidatePointScale,u.fresnelGlareStrength);
    w+=0.125f*LGCA_DesignedSoftboxCoefficient(
        my,u.refractiveIndex,u.buttonCandidatePointScale,u.fresnelGlareStrength);
    w+=0.125f*LGCA_DesignedSoftboxCoefficient(
        py,u.refractiveIndex,u.buttonCandidatePointScale,u.fresnelGlareStrength);
    return float4(LGCA_DesignedSoftboxPremultipliedChannel(base.r,base.a,w),
                  LGCA_DesignedSoftboxPremultipliedChannel(base.g,base.a,w),
                  LGCA_DesignedSoftboxPremultipliedChannel(base.b,base.a,w),base.a);
}
'''


CA_ADDITION_TEMPLATE = r'''
// ---- CA closed, single-transmission material profile (new entry points) ----
// Existing Uniforms/liquidGlassPixel/liquidGlassFragment above are frozen.
// Host contract: origTex has exactly one mip level; every new sample is level 0.
// LGCA_ identifiers isolate the verified-175 formula family from baseline-149.
@@DSL@@
@@MINIFICATION_HELPER@@
@@DESIGNED_LIGHT_HELPER@@

bool LGCA_ClosedUniformsAreLegal(constant Uniforms &u, uint2 dimensions) {
    float shortest=min(u.resolution.x,u.resolution.y);
    return dimensions.x>0 && dimensions.y>0 &&
        isfinite(u.resolution.x) && isfinite(u.resolution.y) &&
        u.resolution.x>=1.0f && u.resolution.y>=1.0f &&
        isfinite(u.outputResolution.x) && isfinite(u.outputResolution.y) &&
        u.outputResolution.x>=1.0f && u.outputResolution.y>=1.0f &&
        u.useGlyphMask==0.0f && isfinite(u.shapeScale) &&
        u.shapeScale>=0.999f && u.shapeScale<=1.0f &&
        isfinite(u.shapeOrigin.x) && isfinite(u.shapeOrigin.y) &&
        isfinite(u.shapeSize.x) && isfinite(u.shapeSize.y) &&
        u.shapeSize.x>=0.0f && u.shapeSize.y>=0.0f &&
        u.shapeSize.x<=0.5f && u.shapeSize.y<=0.5f &&
        isfinite(u.radius) && isfinite(u.bezelWidth) &&
        isfinite(u.glassThickness) && isfinite(u.refractionScale) &&
        isfinite(u.refractiveIndex) &&
        isfinite(u.buttonCandidateCenter.x) && isfinite(u.buttonCandidateCenter.y) &&
        isfinite(u.buttonCandidateCornerRadius) &&
        isfinite(u.buttonCandidateMaxOffset) &&
        isfinite(u.buttonCandidatePointScale) &&
        isfinite(u.buttonCandidateRendererScale) &&
        isfinite(u.fresnelGlareStrength) &&
        u.buttonCandidateCenter.x>=0.5f &&
        u.buttonCandidateCenter.x<=u.resolution.x-0.5f &&
        u.buttonCandidateCenter.y>=0.5f &&
        u.buttonCandidateCenter.y<=u.resolution.y-0.5f &&
        u.buttonCandidateCornerRadius>=0.0f &&
        u.buttonCandidateCornerRadius<=shortest*0.5f+0.01f &&
        u.radius==u.buttonCandidateCornerRadius &&
        u.bezelWidth>=0.0f && u.glassThickness>=0.0f &&
        u.refractionScale>=0.0f && u.refractionScale<=3.0f &&
        u.refractiveIndex>=1.0f && u.refractiveIndex<=3.2f &&
        u.buttonCandidateMaxOffset>0.0f &&
        u.buttonCandidatePointScale>=0.5f && u.buttonCandidatePointScale<=4.0f &&
        u.buttonCandidateRendererScale>=0.5f && u.buttonCandidateRendererScale<=4.0f &&
        (u.fresnelGlareStrength==0.0f || u.fresnelGlareStrength==1.0f);
}

float4 LGCA_ClosedProfilePixel(texture2d<float, access::sample> src,
                               texture2d<float, access::sample> glyphMask,
                               constant Uniforms &u, uint2 gid, uint2 dimensions) {
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    float2 captureUV=(float2(gid)+0.5f)/float2(dimensions);
    float2 point=captureUV*u.resolution;
    LGCA_ButtonOpticsResult q=LGCA_EvaluateAt(point,u);
    if (!q.valid) return liquidGlassPixel(src,glyphMask,u,gid,dimensions);
    if (q.signedDistance>=0.0f)
        return src.sample(s,captureUV,level(0.0f));

    // Exact +/-0.5-pixel geometry differences feed the verified PSD footprint.
    LGCA_ButtonOpticsResult mx=LGCA_EvaluateAt(point+float2(-0.5f,0.0f),u);
    LGCA_ButtonOpticsResult px=LGCA_EvaluateAt(point+float2( 0.5f,0.0f),u);
    LGCA_ButtonOpticsResult my=LGCA_EvaluateAt(point+float2(0.0f,-0.5f),u);
    LGCA_ButtonOpticsResult py=LGCA_EvaluateAt(point+float2(0.0f, 0.5f),u);
    if (!mx.valid || !px.valid || !my.valid || !py.valid)
        return liquidGlassPixel(src,glyphMask,u,gid,dimensions);

    float2 sxm=LGCA_SourceTexels(mx,src);
    float2 sxp=LGCA_SourceTexels(px,src);
    float2 sym=LGCA_SourceTexels(my,src);
    float2 syp=LGCA_SourceTexels(py,src);
    LGCA_MinificationFootprint footprint=LGCA_BOAnalyzeMinificationFootprint(
        sxp.x-sxm.x,sxp.y-sxm.y,syp.x-sym.x,syp.y-sym.y);
    // No overscan, padding, environment path or second transmission image.
    float4 transmitted=LGCA_MinifiedSample(
        src,s,float2(q.sampleU,q.sampleV),footprint);
    return LGCA_DesignedLighting(transmitted,q,mx,px,my,py,u);
}

fragment float4 liquidGlassCAClosedFragment(
    LGVertexOut in [[stage_in]],
    texture2d<float, access::sample> src [[texture(0)]],
    texture2d<float, access::sample> glyphMask [[texture(1)]],
    constant Uniforms &u [[buffer(0)]],
    device atomic_uint *auditWord [[buffer(1)]]) {
    uint2 dimensions(src.get_width(), src.get_height());
    float2 sourcePosition =
        in.position.xy - (u.outputResolution - u.resolution) * 0.5;
    if (any(sourcePosition < float2(0.0)) ||
        any(sourcePosition >= u.resolution)) return float4(0.0);
    uint2 gid = min(uint2(sourcePosition), dimensions - 1);
    if (atomic_load_explicit(auditWord,memory_order_relaxed)!=0x4c474341u ||
        u.buttonCandidate!=2.0f ||
        !LGCA_ClosedUniformsAreLegal(u,dimensions))
        return liquidGlassPixel(src,glyphMask,u,gid,dimensions);
    return LGCA_ClosedProfilePixel(src,glyphMask,u,gid,dimensions);
}

kernel void LGCAAuditOpaque(
    texture2d<float, access::read> src [[texture(0)]],
    device atomic_uint *auditWord [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x>=src.get_width() || gid.y>=src.get_height()) return;
    float alpha=src.read(gid).a;
    atomic_fetch_add_explicit(auditWord,1u,memory_order_relaxed);
    if (!isfinite(alpha) || alpha!=1.0f)
        atomic_fetch_or_explicit(auditWord,0x80000000u,memory_order_relaxed);
}

kernel void LGCAFinalizeOpaque(
    texture2d<float, access::read> src [[texture(0)]],
    device atomic_uint *auditWord [[buffer(1)]],
    uint tid [[thread_position_in_grid]]) {
    if (tid!=0u) return;
    uint expected=src.get_width()*src.get_height();
    uint observed=atomic_load_explicit(auditWord,memory_order_relaxed);
    bool noBadBit=(observed&0x80000000u)==0u;
    if (noBadBit && observed==expected)
        atomic_store_explicit(auditWord,0x4c474341u,memory_order_relaxed);
    else
        atomic_store_explicit(auditWord,0u,memory_order_relaxed);
}
'''



def split_top(text):
    parts=[]
    start=0
    depth=0
    for i,ch in enumerate(text):
        if ch=='(': depth+=1
        elif ch==')': depth-=1
        elif ch==',' and depth==0:
            parts.append(text[start:i].strip())
            start=i+1
    parts.append(text[start:].strip())
    return parts


def expand_formula(path):
    """Same pure-Python LGBO_* DSL expansion used by the 175 generator."""
    out=[]
    for number,line in enumerate(path.read_text(encoding='utf-8').splitlines(),1):
        s=line.strip()
        if not s or s.startswith('/*') or s.startswith('*') or s.startswith('*/'):
            continue
        if s.startswith('LGBO_STRUCT_BEGIN('):
            out.append('struct '+s[len('LGBO_STRUCT_BEGIN('):-1]+' {\n')
        elif s.startswith('LGBO_FIELD('):
            p=split_top(s[len('LGBO_FIELD('):-1])
            if len(p)!=2: raise ValueError(f'bad FIELD DSL line {number} in {path}')
            out.append(p[0]+' '+p[1]+';\n')
        elif s.startswith('LGBO_STRUCT_END('):
            out.append('};\n')
        elif s.startswith('LGBO_FUNCTION_BEGIN('):
            p=split_top(s[len('LGBO_FUNCTION_BEGIN('):-1])
            if len(p)!=3: raise ValueError(f'bad FUNCTION DSL line {number} in {path}')
            out.append(f'{p[0]} {p[1]}{p[2]} {{\n')
        elif s.startswith('LGBO_STMT('):
            out.append(s[len('LGBO_STMT('):-1]+'\n')
        elif s=='LGBO_FUNCTION_END':
            out.append('}\n')
        else:
            raise ValueError(f'unknown formula DSL at {path}:{number}: {s[:80]}')
    return ''.join(out)


LEXEME = re.compile(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[A-Za-z_]\w*', re.S)
NAME_MAP = (('LGButtonOptics','LGCA_ButtonOptics'),
            ('LGMinification','LGCA_Minification'),
            ('LGDesigned','LGCA_Designed'),
            ('LGBO','LGCA_BO'))
REVERSE_NAME_MAP = tuple((new,old) for old,new in NAME_MAP)


def rename_code_identifiers(text, mapping=NAME_MAP):
    """Prefix only code identifiers; leave comments, strings and math intact."""
    def replace(match):
        token=match.group(0)
        if token.startswith(('/*','//','"',"'")):
            return token
        for old,new in mapping:
            if token.startswith(old):
                return new+token[len(old):]
        return token
    return LEXEME.sub(replace,text)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def extract_braced(data, anchor, trailing_semicolon=False):
    start=data.find(anchor)
    if start<0: raise ValueError(f'missing frozen declaration {anchor!r}')
    opening=data.find(b'{',start)
    if opening<0: raise ValueError(f'missing body for {anchor!r}')
    depth=0
    for i in range(opening,len(data)):
        if data[i:i+1]==b'{': depth+=1
        elif data[i:i+1]==b'}':
            depth-=1
            if depth==0:
                end=i+1
                if trailing_semicolon:
                    if data[end:end+1]!=b';': raise ValueError('struct terminator drift')
                    end+=1
                return data[start:end]
    raise ValueError(f'unclosed frozen declaration {anchor!r}')


def read_raw_shader(path):
    text=path.read_bytes()
    matches=list(re.finditer(rb'kShaderSrc\s*=\s*R"MSL\((.*?)\)MSL";',text,re.S))
    if len(matches)!=1: raise ValueError(f'expected one raw kShaderSrc in {path}')
    return matches[0].group(1)


def make_addition(shared_dir):
    formula_path=shared_dir/'LGButtonOpticsFormula.inc'
    min_path=shared_dir/'LGLocalMinification.inc'
    light_path=shared_dir/'LGDesignedLighting.inc'
    expanded=(expand_formula(formula_path)+expand_formula(min_path)+
              expand_formula(light_path))
    renamed=rename_code_identifiers(expanded)
    # Reversibility proves prefixing touched identifiers only, not formula math.
    if rename_code_identifiers(renamed,REVERSE_NAME_MAP)!=expanded:
        raise ValueError('175 identifier renaming changed non-identifier source text')
    addition=CA_ADDITION_TEMPLATE.replace('@@DSL@@',renamed)
    addition=addition.replace('@@MINIFICATION_HELPER@@',MINIFICATION_HELPER)
    addition=addition.replace('@@DESIGNED_LIGHT_HELPER@@',DESIGNED_LIGHT_HELPER)
    if '@@' in addition: raise ValueError('unexpanded helper placeholder')
    if re.search(r'\b(?:LGButtonOptics|LGBO|LGMinification|LGDesigned)\w*',renamed):
        raise ValueError('unprefixed 175 DSL identifier remains')
    if 'buttonSourceOverscanEnabled' in addition:
        raise ValueError('closed path unexpectedly depends on overscan')
    if 'LGCA_BOEnvironmentMixPremultipliedChannel(' in CA_ADDITION_TEMPLATE:
        raise ValueError('closed helper must not invoke an environment mix')
    if addition.count('LGCA_BOEnvironmentMixPremultipliedChannel(')!=1:
        raise ValueError('175 environment-mix DSL must remain declaration-only')
    return addition.encode('utf-8'), {p.name:sha(p.read_bytes()) for p in
        (formula_path,min_path,light_path)}


def build(args):
    out_dir=args.out_dir.resolve()
    if not args.baseline.is_file() or not args.baseline_dsl.is_file():
        raise ValueError('Pinned baseline inputs are required')
    out_dir.mkdir(parents=True,exist_ok=True)
    raw=read_raw_shader(args.baseline)
    if raw.count(MARKER)!=1: raise ValueError('baseline marker count is not exactly one')
    raw_text=raw.decode('utf-8')
    baseline_formula=expand_formula(args.baseline_dsl).encode('utf-8')
    baseline=COMPILE_PREFIX+raw.replace(MARKER,baseline_formula,1)
    if not baseline.startswith(COMPILE_PREFIX): raise ValueError('compile prefix drift')
    if extract_braced(raw,b'struct Uniforms {',True)!=extract_braced(baseline,b'struct Uniforms {',True):
        raise ValueError('baseline Uniforms bytes changed')
    if extract_braced(raw,b'float4 liquidGlassPixel(')!=extract_braced(baseline,b'float4 liquidGlassPixel('):
        raise ValueError('baseline liquidGlassPixel bytes changed')
    addition,profile_hashes=make_addition(args.profile_shared)
    final=baseline+addition
    if not final.startswith(baseline): raise ValueError('baseline is not an exact final-source prefix')
    if final.count(b'struct Uniforms {')!=1: raise ValueError('new Uniforms ABI declaration detected')
    if final.count(b'float4 liquidGlassPixel(')!=1: raise ValueError('baseline pixel function was duplicated')
    if final.count(b'fragment float4 liquidGlassFragment(')!=1: raise ValueError('baseline fragment drift')
    for token in (b'fragment float4 liquidGlassCAClosedFragment(',
                  b'kernel void LGCAAuditOpaque(', b'kernel void LGCAFinalizeOpaque(',
                  b'atomic_load_explicit(auditWord,memory_order_relaxed)!=0x4c474341u',
                  b'atomic_fetch_add_explicit(auditWord,1u,memory_order_relaxed)',
                  b'atomic_fetch_or_explicit(auditWord,0x80000000u,memory_order_relaxed)',
                  b'atomic_store_explicit(auditWord,0x4c474341u,memory_order_relaxed)',
                  b'atomic_store_explicit(auditWord,0u,memory_order_relaxed)',
                  b'uint expected=src.get_width()*src.get_height()',
                  b'bool noBadBit=(observed&0x80000000u)==0u',
                  b'observed==expected', b'uint tid [[thread_position_in_grid]]',
                  b'u.buttonCandidate!=2.0f', b'u.useGlyphMask==0.0f',
                  b'u.shapeScale>=0.999f', b'u.shapeSize.x<=0.5f',
                  b'u.shapeSize.y<=0.5f',
                  b'(u.fresnelGlareStrength==0.0f || u.fresnelGlareStrength==1.0f)',
                  b'point+float2(-0.5f,0.0f)', b'point+float2( 0.5f,0.0f)',
                  b'LGCA_BOAnalyzeMinificationFootprint(',
                  b'LGCA_MinifiedSample(', b'LGCA_DesignedLighting('):
        if token not in final: raise ValueError(f'required profile contract missing: {token!r}')
    frag=addition.decode('utf-8').split('fragment float4 liquidGlassCAClosedFragment(',1)[1]
    if not (frag.index('atomic_load_explicit') < frag.index('LGCA_ClosedUniformsAreLegal') <
            frag.index('LGCA_ClosedProfilePixel(')):
        raise ValueError('new geometry must remain behind the finalized audit token')
    delimiter=b')LGCA_PROF"'
    if delimiter in final: raise ValueError('raw-string delimiter collision')

    addition_path=out_dir/'LGCAClosedProfile.helpers.metal'
    baseline_path=out_dir/'baseline.metal'
    final_path=out_dir/'LiquidAssCAClosed.metal'
    header_path=out_dir/'LGCAClosedProfileShaderSource.h'
    provenance_path=out_dir/'provenance.json'
    baseline_path.write_bytes(baseline)
    addition_path.write_bytes(addition)
    final_path.write_bytes(final)
    final_hash=sha(final)
    baseline_hash=sha(baseline)
    profile_delimiter=b')LGCA_PROF"'
    baseline_delimiter=b')LGCA_BASE"'
    if profile_delimiter in final or baseline_delimiter in baseline:
        raise ValueError('raw-string delimiter collision')
    header=(b'/* Generated by generate_ca_closed_shader.py; do not edit. */\n'
            b'#pragma once\n'
            b'static const char kLGCAClosedProfileMSL[] = R"LGCA_PROF('+final+b')LGCA_PROF";\n'
            b'static const char kLGCAClosedProfileMSLSHA256[] = "'+final_hash.encode('ascii')+b'";\n'
            b'static const char kLGCAClosedBaselineMSL[] = R"LGCA_BASE('+baseline+b')LGCA_BASE";\n'
            b'static const char kLGCAClosedBaselineMSLSHA256[] = "'+baseline_hash.encode('ascii')+b'";\n')
    header_path.write_bytes(header)
    provenance={
        'generator':'generate_ca_closed_shader.py',
        'inputs':{
            'baseline_tweak_mm':{'path':str(args.baseline),'sha256':sha(args.baseline.read_bytes())},
            'baseline_raw_kShaderSrc':{'sha256':sha(raw),'bytes':len(raw)},
            'baseline_149_formula_dsl':{'path':str(args.baseline_dsl),'sha256':sha(args.baseline_dsl.read_bytes())},
            'profile_175_generator':{'path':str(args.profile_generator),'sha256':sha(args.profile_generator.read_bytes())},
            'profile_175_dsl_sha256':profile_hashes,
        },
        'outputs':{
            'baseline.metal':{'sha256':sha(baseline),'bytes':len(baseline)},
            'LGCAClosedProfile.helpers.metal':{'sha256':sha(addition),'bytes':len(addition)},
            'LiquidAssCAClosed.metal':{'sha256':final_hash,'bytes':len(final)},
            'LGCAClosedProfileShaderSource.h':{'sha256':sha(header),'bytes':len(header)},
        },
        'invariants':{
            'final_starts_with_exact_baseline_metal':True,
            'baseline_Uniforms_and_liquidGlassPixel_byte_identical_to_raw':True,
            'new_uniform_fields':0,
            'audit_requires_exact_opaque_alpha':True,
            'audit_counter_requires_full_pixel_count':True,
            'audit_badbit_mask':'0x80000000u',
            'finalizer_accept_magic':'0x4c474341u',
            'finalizer_is_single_threaded':True,
            'supported_mipmap_level_count':1,
            'profile_gate_buttonCandidate_exactly_2_and_full_shape':True,
            'new_secondary_environment_path':False,
            'new_overscan_path':False,
        },
    }
    provenance_path.write_text(json.dumps(provenance,indent=2,sort_keys=True)+'\n',encoding='utf-8')
    print(f'baseline: {baseline_path} sha256={sha(baseline)} bytes={len(baseline)}')
    print(f'helpers:  {addition_path} sha256={sha(addition)} bytes={len(addition)}')
    print(f'library:  {final_path} sha256={final_hash} bytes={len(final)}')
    print(f'header:   {header_path} sha256={sha(header)}')
    print(f'manifest: {provenance_path}')


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--baseline',type=Path,default=BASELINE)
    ap.add_argument('--baseline-dsl',type=Path,default=BASELINE_DSL)
    ap.add_argument('--profile-shared',type=Path,default=PROFILE_SHARED)
    ap.add_argument('--profile-generator',type=Path,default=PROFILE_GENERATOR)
    ap.add_argument('--out-dir',type=Path,default=WORKSPACE)
    args=ap.parse_args()
    try:
        build(args)
    except (OSError,UnicodeError,ValueError) as exc:
        raise SystemExit(f'generate_ca_closed_shader.py: {exc}')

if __name__=='__main__':
    main()
