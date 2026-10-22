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
OVERSCAN_FIELDS=('    float2 buttonSourceTargetOriginPixels;\n'
                 '    float buttonSourceOverscanEnabled;\n')
SOURCE_UV_HELPER='''
float2 localButtonSourceUV(texture2d<float, access::sample> src,
                           constant Uniforms &u, float2 targetUV) {
    if (u.buttonSourceOverscanEnabled <= 0.5f) return targetUV;
    return float2(
        LGBOMapTargetUVToSource(targetUV.x,u.resolution.x,(float)src.get_width(),u.buttonSourceTargetOriginPixels.x,true),
        LGBOMapTargetUVToSource(targetUV.y,u.resolution.y,(float)src.get_height(),u.buttonSourceTargetOriginPixels.y,true));
}
'''
MINIFICATION_MSL_HELPER='''
float2 localButtonCandidateTargetUV(LGButtonOpticsResult q, float2 point,
                                    bool environmentPath, constant Uniforms &u) {
    if (u.buttonSourceOverscanEnabled > 0.5f) {
        float2 offset = environmentPath
            ? float2(q.environmentOffsetX,q.environmentOffsetY)
            : float2(q.offsetX,q.offsetY);
        return (point + offset) / u.resolution;
    }
    return environmentPath ? float2(q.environmentU,q.environmentV)
                           : float2(q.sampleU,q.sampleV);
}

LGButtonOpticsResult localButtonEvaluateAt(float2 point, float width, float height,
                                           float bezel, constant Uniforms &u) {
    return LGButtonOpticsEvaluateWithContact(
        point.x,point.y,width,height,u.buttonCandidateCenter.x,
        u.buttonCandidateCenter.y,u.buttonCandidateCornerRadius,bezel,
        u.glassThickness,u.refractiveIndex,u.refractionScale,
        u.buttonCandidateMaxOffset,u.buttonCandidatePointScale,
        u.buttonCandidateRendererScale,true,u.buttonContactEnabled > 0.5f,
        u.buttonContactCenter.x,u.buttonContactCenter.y,
        u.buttonContactPressure);
}

float2 localButtonSourceTexels(texture2d<float, access::sample> src,
                               constant Uniforms &u, LGButtonOpticsResult q,
                               float2 point, bool environmentPath) {
    float2 targetUV=localButtonCandidateTargetUV(q,point,environmentPath,u);
    return localButtonSourceUV(src,u,targetUV) *
           float2((float)src.get_width(),(float)src.get_height());
}

float4 localButtonMinifiedSample(texture2d<float, access::sample> source,
                                 sampler s, float2 sourceUV,
                                 LGMinificationFootprint footprint) {
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
DESIGNED_LIGHT_MSL_HELPER='''
float4 localButtonDesignedLighting(float4 base,
                                  LGButtonOpticsResult q,
                                  LGButtonOpticsResult mx, LGButtonOpticsResult px,
                                  LGButtonOpticsResult my, LGButtonOpticsResult py,
                                  constant Uniforms &u) {
    if (!isfinite(u.fresnelGlareStrength) || u.fresnelGlareStrength<=0.0f)
        return base;
    // Finite pixel-footprint smoothing reuses the existing four exact optical
    // evaluations; no texture writes/capture or extra optical evaluations.
    float w=0.5f*LGDesignedSoftboxCoefficient(q,u.refractiveIndex,u.buttonCandidatePointScale,u.fresnelGlareStrength);
    w+=0.125f*LGDesignedSoftboxCoefficient(mx,u.refractiveIndex,u.buttonCandidatePointScale,u.fresnelGlareStrength);
    w+=0.125f*LGDesignedSoftboxCoefficient(px,u.refractiveIndex,u.buttonCandidatePointScale,u.fresnelGlareStrength);
    w+=0.125f*LGDesignedSoftboxCoefficient(my,u.refractiveIndex,u.buttonCandidatePointScale,u.fresnelGlareStrength);
    w+=0.125f*LGDesignedSoftboxCoefficient(py,u.refractiveIndex,u.buttonCandidatePointScale,u.fresnelGlareStrength);
    return float4(LGDesignedSoftboxPremultipliedChannel(base.r,base.a,w),
                  LGDesignedSoftboxPremultipliedChannel(base.g,base.a,w),
                  LGDesignedSoftboxPremultipliedChannel(base.b,base.a,w),base.a);
}
'''

EDGE_RADIANCE_MSL_HELPER='''
float4 localButtonEdgeRadianceSample(texture2d<float, access::sample> src,
                                     sampler s, float2 targetPoint,
                                     constant Uniforms &u, thread bool &sourceValid) {
    sourceValid=false;
    float2 dimensions=float2((float)src.get_width(),(float)src.get_height());
    float2 halfTexel=0.5f/dimensions;
    float2 highUV=1.0f-halfTexel;
    float2 roiMin=u.buttonSourceTargetOriginPixels/dimensions;
    float2 roiMax=(u.buttonSourceTargetOriginPixels+u.resolution)/dimensions;
    float2 legalPad=float2(16.0f*u.buttonCandidatePointScale)/dimensions;
    float2 lowUV=max(halfTexel,roiMin-legalPad);
    float2 legalHighUV=min(highUV,roiMax+legalPad);
    LGBOEdgeExteriorPatch patch=LGBOBuildEdgeExteriorPatch(targetPoint.x,targetPoint.y,
        u.resolution.x,u.resolution.y,u.buttonCandidateCenter.x,u.buttonCandidateCenter.y,
        u.buttonCandidateCornerRadius,u.bezelWidth,u.buttonCandidatePointScale);
    if (!patch.valid) return float4(0.0f);
    float2 origin=u.buttonSourceTargetOriginPixels;
    float2 p0=(origin+float2(LGBOExteriorPatchSampleX(patch,0),LGBOExteriorPatchSampleY(patch,0)))/dimensions;
    float2 p1=(origin+float2(LGBOExteriorPatchSampleX(patch,1),LGBOExteriorPatchSampleY(patch,1)))/dimensions;
    float2 p2=(origin+float2(LGBOExteriorPatchSampleX(patch,2),LGBOExteriorPatchSampleY(patch,2)))/dimensions;
    float2 p3=(origin+float2(LGBOExteriorPatchSampleX(patch,3),LGBOExteriorPatchSampleY(patch,3)))/dimensions;
    // Missing captured pixels are not repaired by edge-repeat clamping.
    if (any(p0<lowUV)||any(p0>legalHighUV)||any(p1<lowUV)||any(p1>legalHighUV)||
        any(p2<lowUV)||any(p2>legalHighUV)||any(p3<lowUV)||any(p3>legalHighUV)) return float4(0.0f);
    sourceValid=true;
    float4 a=src.sample(s,p0,level(0.0f));
    float4 b=src.sample(s,p1,level(0.0f));
    float4 c=src.sample(s,p2,level(0.0f));
    float4 d=src.sample(s,p3,level(0.0f));
    return float4(
        LGBOAverageFourRadianceSamples(a.r,b.r,c.r,d.r),
        LGBOAverageFourRadianceSamples(a.g,b.g,c.g,d.g),
        LGBOAverageFourRadianceSamples(a.b,b.b,c.b,d.b),
        LGBOAverageFourRadianceSamples(a.a,b.a,c.a,d.a));
}
'''


def wrap_local_source_samples(source):
    needle='src.sample(s,'
    cursor=0
    while True:
        start=source.find(needle,cursor)
        if start<0: return source
        open_paren=source.find('(',start)
        depth=0; close=None
        for i in range(open_paren,len(source)):
            if source[i]=='(': depth+=1
            elif source[i]==')':
                depth-=1
                if depth==0: close=i; break
        if close is None: raise SystemExit('unbalanced src.sample expression')
        expr=source[start+len(needle):close]
        replacement='src.sample(s, localButtonSourceUV(src, u, '+expr+'))'
        source=source[:start]+replacement+source[close+1:]
        cursor=start+len(replacement)


def add_overscan_fragment_domain(source):
    anchor='    uint2 dimensions(src.get_width(), src.get_height());\n'
    branch='''    if (u.buttonSourceOverscanEnabled > 0.5f) {
        float2 targetPosition=in.position.xy-(u.outputResolution-u.resolution)*0.5f;
        if (any(targetPosition<float2(0.0f)) || any(targetPosition>=u.resolution))
            return float4(0.0f);
        uint2 targetDimensions=max(uint2(u.resolution),uint2(1));
        uint2 targetGid=min(uint2(targetPosition),targetDimensions-1);
        return liquidGlassPixel(src,glyphMask,u,targetGid,targetDimensions);
    }
'''
    if source.count(anchor)!=1: raise SystemExit('fragment target-domain anchor drift')
    return source.replace(anchor,branch+anchor,1)


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
    contact_field='    float buttonContactEnabled;\n'
    if base.count(contact_field)!=1: raise SystemExit('contact tail anchor drift')
    base=base.replace(contact_field,contact_field+OVERSCAN_FIELDS,1)
    helper_anchor='    float buttonSourceOverscanEnabled;\n};\n'
    if base.count(helper_anchor)!=1: raise SystemExit('Uniforms overscan tail anchor drift')
    # The mapping helper depends on LGBOClamp from the formula. Emit both only
    # after the single real raw-shader marker; never a call before definition.
    base=wrap_local_source_samples(base)
    base=add_overscan_fragment_domain(base)
    base=base.replace(call,'LGButtonOpticsResult optics = LGButtonOpticsEvaluateWithContact(',1)
    old_tail='u.buttonCandidatePointScale, u.buttonCandidateRendererScale, true);'
    new_tail=('u.buttonCandidatePointScale, u.buttonCandidateRendererScale, true,\n'
              '            u.buttonContactEnabled > 0.5f, u.buttonContactCenter.x,\n'
              '            u.buttonContactCenter.y, u.buttonContactPressure);\n'
              '        optics.environmentWeight=LGBOImageEdgeRadianceWeight(\n'
              '            optics,fw,fh,bezel,u.buttonCandidatePointScale,\n'
              '            u.refractiveIndex,true,u.buttonSourceOverscanEnabled > 0.5f);')
    if base.count(old_tail)!=1: raise SystemExit('raw candidate call argument anchor drift')
    base=base.replace(old_tail,new_tail,1)
    old_environment_comment='''        /* Source-plane radiance approximation: a second low-cost sample from
         * the same live CA origTex. This is not an external environment map. */'''
    new_environment_comment='''        /* Candidate-only four-point low-frequency radiance integral from the
         * same leased source. It is not a second clear image or reflection map. */'''
    if base.count(old_environment_comment)!=1:
        raise SystemExit('raw environment comment anchor drift')
    base=base.replace(old_environment_comment,new_environment_comment,1)
    optical='        float2 opticalUV = float2(optics.sampleU, optics.sampleV);'
    environment='        float2 environmentUV = float2(optics.environmentU, optics.environmentV);'
    if base.count(optical)!=1 or base.count(environment)!=1:
        raise SystemExit('candidate actual optical/environment source anchors drift')
    base=base.replace(optical,optical+'\n        if (u.buttonSourceOverscanEnabled > 0.5f)\n            opticalUV=(capturePx+float2(optics.offsetX,optics.offsetY))/u.resolution;',1)
    base=base.replace(environment,environment+'\n        if (u.buttonSourceOverscanEnabled > 0.5f)\n            environmentUV=(capturePx+float2(optics.environmentOffsetX,optics.environmentOffsetY))/u.resolution;',1)
    optical_setup=optical+'\n        if (u.buttonSourceOverscanEnabled > 0.5f)\n            opticalUV=(capturePx+float2(optics.offsetX,optics.offsetY))/u.resolution;'
    footprint_code='''
        LGButtonOpticsResult localButtonMinusX = localButtonEvaluateAt(float2(px.x-0.5f,px.y),fw,fh,bezel,u);
        LGButtonOpticsResult localButtonPlusX  = localButtonEvaluateAt(float2(px.x+0.5f,px.y),fw,fh,bezel,u);
        LGButtonOpticsResult localButtonMinusY = localButtonEvaluateAt(float2(px.x,px.y-0.5f),fw,fh,bezel,u);
        LGButtonOpticsResult localButtonPlusY  = localButtonEvaluateAt(float2(px.x,px.y+0.5f),fw,fh,bezel,u);
        float2 localOpticalMinusX=localButtonSourceTexels(src,u,localButtonMinusX,float2(px.x-0.5f,px.y),false);
        float2 localOpticalPlusX =localButtonSourceTexels(src,u,localButtonPlusX, float2(px.x+0.5f,px.y),false);
        float2 localOpticalMinusY=localButtonSourceTexels(src,u,localButtonMinusY,float2(px.x,px.y-0.5f),false);
        float2 localOpticalPlusY =localButtonSourceTexels(src,u,localButtonPlusY, float2(px.x,px.y+0.5f),false);
        LGMinificationFootprint opticalFootprint=LGBOAnalyzeMinificationFootprint(
            localOpticalPlusX.x-localOpticalMinusX.x,localOpticalPlusX.y-localOpticalMinusX.y,
            localOpticalPlusY.x-localOpticalMinusY.x,localOpticalPlusY.y-localOpticalMinusY.y);
'''
    if base.count(optical_setup)!=1: raise SystemExit('candidate optical UV setup anchor drift')
    base=base.replace(optical_setup,optical_setup+'\n'+footprint_code,1)
    old_optical_sample='        float4 opticalSample = src.sample(s, localButtonSourceUV(src, u,  opticalUV));'
    new_optical_sample='''        float4 opticalSample;
        if (opticalFootprint.tapCount > 1)
            opticalSample=localButtonMinifiedSample(src,s,localButtonSourceUV(src,u,opticalUV),opticalFootprint);
        else
            opticalSample=src.sample(s,localButtonSourceUV(src,u,opticalUV));'''
    old_environment_sample='        float4 environmentSample = src.sample(s, localButtonSourceUV(src, u,  environmentUV));'
    new_environment_sample='''        float4 environmentSample=opticalSample;
        if (u.buttonSourceOverscanEnabled > 0.5f && optics.environmentWeight > 0.0f) {
            bool edgeSourceValid=false;
            environmentSample=localButtonEdgeRadianceSample(src,s,px,u,edgeSourceValid);
            if (!edgeSourceValid) optics.environmentWeight=0.0f;
        }'''
    if base.count(old_optical_sample)!=1 or base.count(old_environment_sample)!=1:
        raise SystemExit('candidate optical/environment sample anchors drift')
    base=base.replace(old_optical_sample,new_optical_sample,1)
    base=base.replace(old_environment_sample,new_environment_sample,1)
    mix_anchor='        float environmentWeight = clamp(optics.environmentWeight, 0.0f, 0.28f);'
    if base.count(mix_anchor)!=1: raise SystemExit('real final mix anchor drift')
    base=base.replace(mix_anchor,mix_anchor+'\n        if (environmentWeight <= 0.0f) return opticalSample;',1)
    # The authored illumination is independent from captured source radiance.
    # Its exact opt-in is zero in the real product's uniform builder.
    illumination_anchor='        if (opticalSample.a < 0.01f) opticalSample = src.sample(s, localButtonSourceUV(src, u,  captureUV));'
    if base.count(illumination_anchor)!=1: raise SystemExit('designed-light primary anchor drift')
    base=base.replace(illumination_anchor,illumination_anchor+'\n        if (u.fresnelGlareStrength > 0.0f) opticalSample=localButtonDesignedLighting(opticalSample,optics,localButtonMinusX,localButtonPlusX,localButtonMinusY,localButtonPlusY,u);',1)
    formula=expand_formula(SHARED/'LGButtonOpticsFormula.inc')
    formula+=expand_formula(SHARED/'LGLocalSourceMapping.inc')
    formula+=expand_formula(SHARED/'LGLocalMinification.inc')
    formula+=expand_formula(SHARED/'LGEdgeExteriorPatch.inc')
    formula+=expand_formula(SHARED/'LGDesignedLighting.inc')+SOURCE_UV_HELPER+MINIFICATION_MSL_HELPER+EDGE_RADIANCE_MSL_HELPER+DESIGNED_LIGHT_MSL_HELPER
    source='#define LG_BUTTON_OPTICS_COMPILED 1\n'+base.replace(MARKER,formula)
    definition='LGButtonOpticsResult LGButtonOpticsEvaluateWithContact('
    actual_call='LGButtonOpticsResult optics = LGButtonOpticsEvaluateWithContact('
    if source.count(definition)!=1 or source.count(actual_call)!=1:
        raise SystemExit('contact function definition/call marker count drift')
    if source.index(definition)>=source.index(actual_call):
        raise SystemExit('contact call precedes shared formula definition')
    if source.count('float buttonContactEnabled;')!=1 or source.count('float2 buttonSourceTargetOriginPixels;')!=1 or source.count('float buttonSourceOverscanEnabled;')!=1:
        raise SystemExit('generated MSL local source-domain ABI field count drift')
    if 'float2 localButtonSourceUV(' not in source or source.count('src.sample(s, localButtonSourceUV(')<1:
        raise SystemExit('generated MSL source sampler map missing')
    if 'targetPosition>=u.resolution' not in source:
        raise SystemExit('generated MSL target UV mask missing')
    if source.count('localButtonEvaluateAt(float2(px.x')!=4:
        raise SystemExit('generated MSL finite-difference footprint count drift')
    if source.index('LGMinificationFootprint opticalFootprint=') > source.index('float4 opticalSample;'):
        raise SystemExit('optical sample appears before its bounded footprint')
    if 'opticalSample=src.sample(s,localButtonSourceUV(src,u,opticalUV));' not in source:
        raise SystemExit('primary direct sampler path drift')
    if 'environmentSample=localButtonEdgeRadianceSample(' not in source:
        raise SystemExit('edge-radiance integrator was not emitted')
    if 'u.buttonSourceOverscanEnabled > 0.5f && optics.environmentWeight > 0.0f' not in source:
        raise SystemExit('edge-radiance lease/zero-weight gate missing')
    edge_helper=source.split('float4 localButtonEdgeRadianceSample(',1)[1].split('\n}',1)[0]
    if edge_helper.count('src.sample(s,')!=4:
        raise SystemExit('edge-radiance tap budget must be exactly four')
    if 'LGBOAverageFourRadianceSamples(a.r,b.r,c.r,d.r)' not in edge_helper:
        raise SystemExit('shared convex quadrature formula missing')
    if 'LGBOImageEdgeRadianceWeight(' not in source or 'LGBOBuildEdgeExteriorPatch(' not in edge_helper:
        raise SystemExit('shared edge weight/exterior-patch math missing')
    if 'source.sample(s,a,level(0.0f))' not in source or 'source.sample(s,e,level(0.0f))' not in source:
        raise SystemExit('bounded primary level-zero taps missing')
    if re.search(r'\b(?:ddx|ddy)\s*\(',source):
        raise SystemExit('fragment derivatives must not enter shared shader call chain')
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
