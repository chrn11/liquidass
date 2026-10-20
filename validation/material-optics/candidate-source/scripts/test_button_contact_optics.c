/* CPU numeric contract for spatial contact. Run only on macOS CI clang. */
#include "LGLocalButtonUniforms.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "legacy_button_optics_cpu_fixture.h"

#define REQUIRE(c, m) do { if (!(c)) { fprintf(stderr,"FAIL: %s (%s:%d)\n",m,__FILE__,__LINE__); return 1; } } while (0)

typedef struct {
    simd_float2 resolution, outputResolution, screenResolution, cardOrigin;
    simd_float2 wallpaperResolution, lensOrigin;
    float radius, bezelWidth, glassThickness, refractionScale, refractiveIndex;
    simd_float2 wallpaperOrigin, samplingTransformX, samplingTransformY;
    simd_float2 samplingTransformOffset;
    float samplingOrientation, backdropZoom, shapeScale;
    simd_float2 shapeOrigin, shapeSize;
    float useGlyphMask, dispersionStrength, fresnelGlareStrength, borderWidthPixels;
    simd_float4 tintColor;
    float buttonCandidate, buttonCandidateMaxOffset;
    simd_float2 buttonCandidateCenter;
    float buttonCandidatePointScale, buttonCandidateCornerRadius;
    float buttonCandidateRendererScale;
} LegacyUniforms208;
_Static_assert(sizeof(LegacyUniforms208)==208,"frozen legacy ABI must remain 208 bytes");
_Static_assert(offsetof(LegacyUniforms208,buttonCandidateRendererScale)==200,"legacy ABI offset drift");
_Static_assert(sizeof(LGLocalButtonUniforms)==240,"overscan ABI must be 240 bytes");
_Static_assert(offsetof(LGLocalButtonUniforms,buttonContactCenter)==208,"contact ABI offset drift");
_Static_assert(offsetof(LGLocalButtonUniforms,buttonContactPressure)==216,"contact ABI offset drift");
_Static_assert(offsetof(LGLocalButtonUniforms,buttonContactEnabled)==220,"contact ABI offset drift");

static int sameResult(LGButtonOpticsResult a, LGButtonOpticsResult b) {
    return a.signedDistance==b.signedDistance && a.offsetX==b.offsetX &&
        a.offsetY==b.offsetY && a.height==b.height && a.normalX==b.normalX &&
        a.normalY==b.normalY && a.sampleU==b.sampleU && a.sampleV==b.sampleV &&
        a.environmentU==b.environmentU && a.environmentV==b.environmentV &&
        a.environmentWeight==b.environmentWeight && a.valid==b.valid;
}
static LGButtonOpticsResult eval(float x,float y,float w,float h,float scale,
                                  bool on,float tx,float ty,float pressure) {
    return LGButtonOpticsEvaluateWithContact(x,y,w,h,w*.5f,h*.5f,
        fminf(w,h)*.5f,16.0f*scale,108.0f,1.6f,2.0f,
        LGButtonCandidateMaxDisplacement(w,h),scale,scale,true,on,tx,ty,pressure);
}
static void contractForScale(float scale,LGLocalButtonSourceContract *c,uint64_t gen) {
    *c=(LGLocalButtonSourceContract){0};
    c->sourceRectInOwnerPoints=CGRectMake(0,0,44,44);
    c->targetRectInOwnerPoints=CGRectMake(0,0,44,44);
    c->textureWidth=(uint32_t)lrintf(44.0f*scale);
    c->textureHeight=(uint32_t)lrintf(44.0f*scale);
    c->pointScale=scale;c->targetGeometryGeneration=gen;
}

static int testNoContactAndFiniteScaleGrid(void) {
    const float scales[]={0.5f,1.0f,1.5f,2.0f,3.0f,4.0f};
    for (unsigned i=0;i<sizeof(scales)/sizeof(scales[0]);i++) {
        float s=scales[i],w=44.0f*s,h=44.0f*s,x=w*.5f,y=h*.5f;
        LGButtonOpticsResult old=LGButtonOpticsEvaluate(x,y,w,h,x,y,
            fminf(w,h)*.5f,16*s,108,1.6f,2,
            LGButtonCandidateMaxDisplacement(w,h),s,s,true);
        LGButtonOpticsResult no=eval(x,y,w,h,s,false,.44f,.5f,1.0f);
        LGButtonOpticsResult zero=eval(x,y,w,h,s,true,.44f,.5f,0.0f);
        REQUIRE(sameResult(old,no),"legacy 208-era no-contact mapping changed");
        REQUIRE(sameResult(old,zero),"zero-pressure contact is not bit-identical");
        LGButtonOpticsResult c=eval(x,y,w,h,s,true,.44f,.45f,.75f);
        REQUIRE(c.valid && isfinite(c.height) && isfinite(c.normalX) &&
            isfinite(c.normalY) && isfinite(c.offsetX) && isfinite(c.offsetY),
            "circle contact result must be finite");
        float cap=LGButtonCandidateMaxDisplacement(w,h);
        REQUIRE(hypotf(c.offsetX,c.offsetY)<=cap+0.0001f,"source UV displacement cap");
        REQUIRE(c.sampleU>=.5f/w && c.sampleU<=1-.5f/w &&
            c.sampleV>=.5f/h && c.sampleV<=1-.5f/h,"half-texel sample clamp");
        REQUIRE(c.environmentU>=.5f/w && c.environmentU<=1-.5f/w &&
            c.environmentV>=.5f/h && c.environmentV<=1-.5f/h,"environment half-texel clamp");

        /* Core-formula capsule (66x44 points) shares the same contact function. */
        float cw=66.0f*s,ch=44.0f*s;
        LGButtonOpticsResult capsule=eval(cw*.5f,ch*.5f,cw,ch,s,true,.44f,.5f,.7f);
        REQUIRE(capsule.valid && isfinite(capsule.height) &&
            isfinite(capsule.normalX) && isfinite(capsule.normalY),"capsule contact finite");
    }
    return 0;
}

static int testSpatialMappingAndGradient(void) {
    const float scales[]={0.5f,1.0f,1.5f,2.0f,3.0f,4.0f};
    for (unsigned i=0;i<sizeof(scales)/sizeof(scales[0]);i++) {
        float s=scales[i],w=44*s,h=44*s,x=w*.5f,y=h*.5f;
        LGButtonOpticsResult left=eval(x,y,w,h,s,true,.44f,.5f,.8f);
        LGButtonOpticsResult right=eval(x,y,w,h,s,true,.56f,.5f,.8f);
        REQUIRE(fabsf(left.sampleU-right.sampleU)>0.00001f,
            "left/right touch must produce different source-plane mapping");
        LGButtonOpticsResult moved=eval(x,y,w,h,s,true,.48f,.46f,.8f);
        REQUIRE(fabsf(left.sampleU-moved.sampleU)>0.000001f ||
            fabsf(left.sampleV-moved.sampleV)>0.000001f,
            "moving the touch must move the optical mapping");

        float qx=x+s,qy=y+0.8f*s,step=0.03f*s;
        LGButtonOpticsResult q=eval(qx,qy,w,h,s,true,.44f,.45f,.8f);
        LGButtonOpticsResult xp=eval(qx+step,qy,w,h,s,true,.44f,.45f,.8f);
        LGButtonOpticsResult xm=eval(qx-step,qy,w,h,s,true,.44f,.45f,.8f);
        LGButtonOpticsResult yp=eval(qx,qy+step,w,h,s,true,.44f,.45f,.8f);
        LGButtonOpticsResult ym=eval(qx,qy-step,w,h,s,true,.44f,.45f,.8f);
        float nz=sqrtf(fmaxf(1.0f-q.normalX*q.normalX-q.normalY*q.normalY,0.000001f));
        float analyticX=-q.normalX/nz,analyticY=-q.normalY/nz;
        float numericX=(xp.height-xm.height)/(2*step);
        float numericY=(yp.height-ym.height)/(2*step);
        REQUIRE(fabsf(analyticX-numericX)<0.055f && fabsf(analyticY-numericY)<0.055f,
            "combined normal must match finite-difference height gradient");
    }
    return 0;
}

static int testStateAndUniformRouting(void) {
    LGButtonOpticalState s={0};
    REQUIRE(LGOpticalSetEligibility(&s,true,true,true,true,true,17),"explicit test state eligible");
    REQUIRE(!LGOpticalBegin(&s,1.0,false,true,10,20,44,44),"rejected UIKit begin ignored");
    REQUIRE(!s.touchValid && !s.tracking,"rejected begin cannot create touch");
    REQUIRE(LGOpticalBegin(&s,1.0,true,true,11,22,44,44),"accepted begin observed");
    REQUIRE(s.touchValid && fabsf(s.touchX-.25f)<1e-6f && fabsf(s.touchY-.5f)<1e-6f,
        "local normalized begin point");
    LGOpticalTick(&s,1.2);
    REQUIRE(s.pressure>0.9f && s.phase==LGOpticalTrackingInside,"continuous press rises");
    LGOpticalContinue(&s,1.21,true,true,33,30,44,44);
    REQUIRE(s.touchValid && fabsf(s.touchX-.75f)<1e-6f &&
        fabsf(s.touchY-30.0f/44.0f)<1e-6f,"drag updates only accepted point");
    LGOpticalContinue(&s,1.22,true,false,-50,500,44,44);
    REQUIRE(s.touchValid && s.touchX==0.0f && s.touchY==1.0f &&
        isfinite(s.touchX) && isfinite(s.touchY),"outside drag is finite and bounded");
    REQUIRE(s.target==0.0f && s.phase==LGOpticalTrackingOutside,
        "outside state follows original tracking and inside result");
    LGOpticalEnd(&s,1.23,false);
    REQUIRE(s.touchValid && s.pressure>0.0f && s.phase==LGOpticalReleasing,
        "release preserves last point during decay");
    LGOpticalTick(&s,10.0);
    REQUIRE(!s.touchValid && s.pressure==0.0f && s.phase==LGOpticalIdle,
        "release clears touch only at zero pressure");

    LGButtonOpticalState c={0};
    REQUIRE(LGOpticalSetEligibility(&c,true,true,true,true,true,18),"cancel state eligible");
    REQUIRE(LGOpticalBegin(&c,3.0,true,true,9,15,44,44),"cancel begin accepted");
    LGOpticalTick(&c,3.2);float before=c.pressure;
    LGOpticalEnd(&c,3.21,true);
    REQUIRE(c.touchValid && c.phase==LGOpticalCancelled,"cancel retains point while fading");
    LGOpticalTick(&c,3.26);
    REQUIRE(c.touchValid && c.pressure<before && c.pressure>0,
        "cancel pressure smoothly decays with position retained");
    LGOpticalSetEligibility(&c,false,true,true,true,true,18);
    REQUIRE(!c.touchValid && c.pressure==0 && !c.eligible,
        "disable immediately clears contact and pressure");

    LGButtonOpticalState a={0},b={0};
    LGOpticalSetEligibility(&a,true,true,true,true,true,21);
    LGOpticalSetEligibility(&b,true,true,true,true,true,21);
    LGOpticalBegin(&a,4,true,true,8,12,44,44);
    LGOpticalBegin(&b,4,true,true,36,32,44,44);
    a.pressure=b.pressure=.8f;
    LGLocalButtonSourceContract ca,cb;contractForScale(1,&ca,21);contractForScale(1,&cb,21);
    LGLocalButtonUniforms ua={0},ub={0};
    REQUIRE(LGLocalButtonBuildUniforms(&ca,&a,44,44,1,true,&ua),"first instance uniforms");
    REQUIRE(LGLocalButtonBuildUniforms(&cb,&b,44,44,1,true,&ub),"second instance uniforms");
    REQUIRE(ua.buttonContactEnabled==1 && ub.buttonContactEnabled==1 &&
        ua.buttonContactCenter.x==a.touchX && ua.buttonContactCenter.y==a.touchY &&
        ub.buttonContactCenter.x==b.touchX && ub.buttonContactCenter.y==b.touchY,
        "two instances retain independent X/Y uniforms");
    LGOpticalContinue(&a,4.1,true,true,40,40,44,44);
    REQUIRE(ub.buttonContactCenter.x==b.touchX && ub.buttonContactCenter.y==b.touchY &&
        fabsf(ub.buttonContactCenter.x-ua.buttonContactCenter.x)>.2f,
        "moving instance A cannot mutate instance B snapshot");

    /* Legacy synthetic pressure-only states are idle and have no valid point. */
    LGButtonOpticalState legacy={0};legacy.eligible=true;legacy.pressure=.5f;
    legacy.geometryGeneration=21;legacy.phase=LGOpticalIdle;legacy.touchX=legacy.touchY=.5f;
    LGLocalButtonUniforms u={0};
    REQUIRE(LGLocalButtonBuildUniforms(&ca,&legacy,44,44,1,true,&u),
        "legacy pressure-only state still builds base material");
    REQUIRE(u.buttonContactEnabled==0 && u.buttonContactPressure==0 &&
        u.buttonContactCenter.x==0 && u.buttonContactCenter.y==0,
        "synthetic idle pressure remains exactly no-contact");
    return 0;
}

static int testUniformScaleAndOptIn(void) {
    const float scales[]={0.5f,1,1.5f,2,3,4};
    for (unsigned i=0;i<6;i++) {
        float s=scales[i],d=44*s;
        LGButtonOpticalState state={0};state.eligible=true;state.pressure=.63f;
        state.geometryGeneration=31;state.touchValid=true;state.phase=LGOpticalTrackingInside;
        state.touchX=.25f;state.touchY=.75f;
        LGLocalButtonSourceContract c;contractForScale(s,&c,31);
        LGLocalButtonUniforms u={0};
        REQUIRE(LGLocalButtonBuildUniforms(&c,&state,d,d,s,false,&u),"default-off ABI build");
        REQUIRE(u.buttonContactEnabled==0 && u.buttonContactPressure==0,
            "default-off contact fields are zero");
        REQUIRE(LGLocalButtonBuildUniforms(&c,&state,d,d,s,true,&u),"explicit local opt-in build");
        REQUIRE(u.buttonContactEnabled==1 && u.buttonContactPressure==state.pressure &&
            u.buttonContactCenter.x==.25f && u.buttonContactCenter.y==.75f,
            "valid contact reaches actual 224-byte ABI at every scale");
        state.phase=LGOpticalIdle;
        REQUIRE(LGLocalButtonBuildUniforms(&c,&state,d,d,s,true,&u) &&
            u.buttonContactEnabled==0,"idle/invalid phase cannot synthesize center touch");
        state.phase=LGOpticalReleasing;state.pressure=0;
        REQUIRE(LGLocalButtonBuildUniforms(&c,&state,d,d,s,true,&u) &&
            u.buttonContactEnabled==0,"zero-pressure release has no residual contact");
        state.phase=LGOpticalCancelled;state.pressure=.3f;
        state.touchX=NAN;
        REQUIRE(LGLocalButtonBuildUniforms(&c,&state,d,d,s,true,&u) &&
            u.buttonContactEnabled==0,"invalid point never reaches shader");
    }
    return 0;
}

static int testOutsideSurfaceIdentity(void) {
    float w=44,h=44,s=1,cap=LGButtonCandidateMaxDisplacement(w,h);
    LGButtonOpticsResult outside=eval(-4,22,w,h,s,true,.4f,.5f,1);
    REQUIRE(outside.valid && outside.signedDistance>=0 && outside.height==0 &&
        outside.offsetX==0 && outside.offsetY==0 && outside.normalX==0 &&
        outside.normalY==0,"outside rounded surface remains identity");
    LGButtonOpticsResult farBase=eval(38,22,w,h,s,false,.2f,.5f,0);
    LGButtonOpticsResult farContact=eval(38,22,w,h,s,true,.2f,.5f,1);
    REQUIRE(farBase.valid && farContact.valid && sameResult(farBase,farContact),
        "finite-support contact is exact identity beyond local radius");
    REQUIRE(hypotf(farContact.offsetX,farContact.offsetY)<=cap+1e-5f,
        "outside-support mapping remains cap bounded");
    return 0;
}

static int testZeroContactMaterialGates(void) {
    const float scales[]={0.5f,1.0f,1.5f,2.0f,3.0f,4.0f};
    for (unsigned i=0;i<6;i++) {
        float s=scales[i],w=44*s,h=44*s,x=.43f*w,y=.47f*h;
        float cap=LGButtonCandidateMaxDisplacement(w,h),r=fminf(w,h)*.5f;
        LGButtonOpticsResult base=LGButtonOpticsEvaluate(x,y,w,h,w*.5f,h*.5f,r,
            16*s,108,1.6f,2,cap,s,s,true);
        LGButtonOpticsResult noContact=eval(x,y,w,h,s,false,.27f,.71f,.9f);
        REQUIRE(sameResult(base,noContact),"disabled contact equals legacy evaluator exactly");
        LGButtonOpticsResult zeroPressure=LGButtonOpticsEvaluateWithContact(x,y,w,h,w*.5f,h*.5f,r,
            16*s,108,1.6f,2,cap,s,s,true,true,.27f,.71f,0);
        REQUIRE(sameResult(base,zeroPressure),"zero contact pressure is exact legacy identity");
        LGButtonOpticsResult zeroThickness=LGButtonOpticsEvaluateWithContact(x,y,w,h,w*.5f,h*.5f,r,
            16*s,0,1.6f,2,cap,s,s,true,true,.27f,.71f,1);
        REQUIRE(zeroThickness.height==0 && zeroThickness.offsetX==0 && zeroThickness.offsetY==0,
            "zero thickness disables all optical contact displacement");
        LGButtonOpticsResult indexOne=LGButtonOpticsEvaluateWithContact(x,y,w,h,w*.5f,h*.5f,r,
            16*s,108,1.0f,2,cap,s,s,true,true,.27f,.71f,1);
        REQUIRE(indexOne.height==0 && indexOne.offsetX==0 && indexOne.offsetY==0,
            "IOR one disables all optical contact displacement");
        LGButtonOpticsResult scaleZero=LGButtonOpticsEvaluateWithContact(x,y,w,h,w*.5f,h*.5f,r,
            16*s,108,1.6f,0,cap,s,s,true,true,.27f,.71f,1);
        REQUIRE(scaleZero.height==0 && scaleZero.offsetX==0 && scaleZero.offsetY==0,
            "refraction scale zero disables all optical contact displacement");
        LGButtonOpticsResult badPoint=LGButtonOpticsEvaluateWithContact(x,y,w,h,w*.5f,h*.5f,r,
            16*s,108,1.6f,2,cap,s,s,true,true,NAN,INFINITY,.8f);
        REQUIRE(sameResult(base,badPoint),"nonfinite point cannot disturb or poison base optics");
    }
    return 0;
}

static int testWholeRasterAgainstFrozenAndThin(void) {
    const float scales[]={.5f,1,1.5f,2,3,4};
    for(unsigned si=0;si<6;si++) {
        float scale=scales[si],w=44*scale,cap=LGButtonCandidateMaxDisplacement(w,w);
        for(int y=0;y<(int)w;y++)for(int x=0;x<(int)w;x++) {
            float px=x+.5f,py=y+.5f;
            LGFrozenButtonOpticsResult frozen=LGFrozenOpticsEvaluate(px,py,w,w,w*.5f,w*.5f,w*.5f,16*scale,108,1.6f,2,cap,scale,scale,true);
            LGButtonOpticsResult current=eval(px,py,w,w,scale,false,.43f,.54f,.8f);
            REQUIRE(frozen.valid==current.valid && frozen.height==current.height &&
                frozen.offsetX==current.offsetX && frozen.offsetY==current.offsetY &&
                frozen.normalX==current.normalX && frozen.normalY==current.normalY &&
                frozen.sampleU==current.sampleU && frozen.sampleV==current.sampleV &&
                frozen.environmentU==current.environmentU && frozen.environmentV==current.environmentV &&
                frozen.environmentWeight==current.environmentWeight,
                "whole raster no-contact differs from the independent frozen formula");
            float thicknesses[]={.0001f,.1f,108.0f};
            for(unsigned ti=0;ti<3;ti++) {
                LGButtonOpticsResult r=LGButtonOpticsEvaluateWithContact(px,py,w,w,w*.5f,w*.5f,w*.5f,
                    16*scale,thicknesses[ti],1.6f,2,cap,scale,scale,true,true,.44f,.53f,1);
                REQUIRE(r.valid && isfinite(r.height) && r.height>=-1e-6f,
                    "a contact dent cannot invert a thin positive material surface");
                REQUIRE(hypotf(r.offsetX,r.offsetY)<=cap+1e-4f,
                    "whole raster contact remains vector cap bounded");
                REQUIRE(r.sampleU>=.5f/w && r.sampleU<=1-.5f/w &&
                    r.sampleV>=.5f/w && r.sampleV<=1-.5f/w,
                    "whole raster source sampling exceeds half-texel bounds");
                if(r.signedDistance>=0)
                    REQUIRE(r.offsetX==0 && r.offsetY==0 && r.height==0 && r.environmentWeight==0,
                        "whole raster outside shape changed under contact");
            }
        }
    }
    return 0;
}

int main(void) {
    if (testNoContactAndFiniteScaleGrid() || testSpatialMappingAndGradient() ||
        testStateAndUniformRouting() || testUniformScaleAndOptIn() ||
        testOutsideSurfaceIdentity() || testZeroContactMaterialGates() ||
        testWholeRasterAgainstFrozenAndThin()) return 1;
    puts("PASS contact CPU numeric/state/ABI contract (not GPU or runtime evidence)");
    return 0;
}
