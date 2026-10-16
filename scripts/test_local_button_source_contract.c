#include "../Shared/LGLocalButtonSourceContract.h"
#include "../Shared/LGLocalButtonUniforms.h"
#include "../Shared/LGButtonMaterialCandidate.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static LGLocalButtonSourceContract fixture(void) {
    LGLocalButtonSourceContract c={0};
    c.sourceRectInOwnerPoints=CGRectMake(10,20,44,44);
    c.targetRectInOwnerPoints=CGRectMake(10,20,44,44);
    c.textureWidth=132; c.textureHeight=132; c.pixelFormat=81; c.pointScale=3;
    c.ownerInstanceToken=17; c.ownerGeneration=4; c.frameGeneration=6;
    c.targetGeometryGeneration=9; c.frameTimestampMonotonic=1.0;
    c.sourceKind=LGLocalSourceLiveAppOwnedTexture;
    c.alphaMode=LGLocalAlphaPremultiplied; c.maskKind=LGLocalMaskRounded44;
    c.backgroundOnly=true; c.targetForegroundExcluded=true;
    c.immutableUntilFrameReleased=true;
    c.sampledRGBIsLinear=true; c.sampledRGBIsPremultiplied=true;
    return c;
}
static LGLocalSourceValidation check(LGLocalButtonSourceContract *c,double now,
    uint64_t owner,uint64_t ownerGen,uint64_t minFrame,uint64_t targetGen,
    uint32_t w,uint32_t h,uint32_t sf,uint32_t df,bool alive,bool approx) {
    return LGLocalValidateSourceContract(c,now,owner,ownerGen,minFrame,targetGen,
                                          w,h,sf,df,alive,approx);
}
int main(void) {
    assert(LG_LOCAL_BUTTON_MAX_OVERSCAN_PADDING_POINTS==16.0);
    LGLocalButtonSourceContract c=fixture();
    assert(check(&c,1.05,17,4,6,9,132,132,81,81,true,false)==LGLocalSourceValid);
    assert(check(&c,1.101,17,4,6,9,132,132,81,81,true,false)==LGLocalSourceStale);
    assert(check(&c,1.0,18,4,6,9,132,132,81,81,true,false)==LGLocalSourceBadOwner);
    assert(check(&c,1.0,17,4,6,9,132,132,81,81,false,false)==LGLocalSourceBadOwner);
    assert(check(&c,1.0,17,5,6,9,132,132,81,81,true,false)==LGLocalSourceBadGeneration);
    assert(check(&c,1.0,17,4,7,9,132,132,81,81,true,false)==LGLocalSourceBadGeneration);
    assert(check(&c,1.0,17,4,6,10,132,132,81,81,true,false)==LGLocalSourceBadGeneration);
    c.frameTimestampMonotonic=NAN;
    assert(check(&c,1.0,17,4,6,9,132,132,81,81,true,false)==LGLocalSourceBadContract);
    c=fixture(); c.frameTimestampMonotonic=INFINITY;
    assert(check(&c,1.0,17,4,6,9,132,132,81,81,true,false)==LGLocalSourceBadContract);
    c=fixture(); c.pointScale=NAN;
    assert(check(&c,1.0,17,4,6,9,132,132,81,81,true,false)==LGLocalSourceBadContract);
    c=fixture(); c.sourceRectInOwnerPoints.origin.x=NAN;
    assert(check(&c,1.0,17,4,6,9,132,132,81,81,true,false)==LGLocalSourceBadGeometry);
    c=fixture(); c.frameTimestampMonotonic=1.01;
    assert(check(&c,1.0,17,4,6,9,132,132,81,81,true,false)==LGLocalSourceStale);
    c=fixture(); c.targetRectInOwnerPoints.origin.x+=1.0;
    assert(check(&c,1.0,17,4,6,9,132,132,81,81,true,false)==LGLocalSourceBadGeometry);
    c=fixture();
    assert(check(&c,1.0,17,4,6,9,131,132,81,81,true,false)==LGLocalSourceBadGeometry);
    c=fixture(); c.sourceRectInOwnerPoints.size.width=43;
    assert(check(&c,1.0,17,4,6,9,132,132,81,81,true,false)==LGLocalSourceBadGeometry);
    c=fixture(); c.pointScale=2;
    assert(check(&c,1.0,17,4,6,9,132,132,81,81,true,false)==LGLocalSourceBadGeometry);
    c=fixture(); c.alphaMode=LGLocalAlphaStraight;
    assert(check(&c,1.0,17,4,6,9,132,132,81,81,true,false)==LGLocalSourceBadAlpha);
    c=fixture(); c.pixelFormat=80;
    assert(check(&c,1.0,17,4,6,9,132,132,80,81,true,false)==LGLocalSourceBadFormat);
    c=fixture(); c.targetForegroundExcluded=false;
    assert(check(&c,1.0,17,4,6,9,132,132,81,81,true,false)==LGLocalSourceHasForeground);
    c=fixture(); c.maskKind=LGLocalMaskGlyph;
    assert(check(&c,1.0,17,4,6,9,132,132,81,81,true,false)==LGLocalSourceBadContract);
    c=fixture(); c.sourceKind=LGLocalSourceStaticAsset;
    assert(check(&c,1.0,17,4,6,9,132,132,81,81,true,false)==LGLocalSourceApproximationNotAllowed);
    assert(check(&c,1.0,17,4,6,9,132,132,81,81,true,true)==LGLocalSourceValid);
    assert(LGLocalSourceIsApproximate(c.sourceKind));
    c.sourceKind=LGLocalSourceDeclaredSyntheticColor;
    assert(LGLocalSourceIsApproximate(c.sourceKind));
    assert(!LGLocalButtonMayRender(false,true,true,true,true,true));
    assert(!LGLocalButtonMayRender(true,false,true,true,true,true));
    assert(!LGLocalButtonMayRender(true,true,false,true,true,true));
    assert(!LGLocalButtonMayRender(true,true,true,false,true,true));
    assert(!LGLocalButtonMayRender(true,true,true,true,false,true));
    assert(!LGLocalButtonMayRender(true,true,true,true,true,false));
    assert(LGLocalButtonMayRender(true,true,true,true,true,true));
    assert(sizeof(LGLocalButtonUniforms)==240);
    LGButtonOpticsGeometry g={};
    assert(LGButtonCandidateBuildGeometry(132,132,132,132,1.0f,&g));
    assert(fabsf(g.centerX-66)<0.01f && fabsf(g.centerY-66)<0.01f);
    assert(!LGButtonCandidateBuildGeometry(132,132,132,120,1.0f,&g));
    LGButtonOpticalState a={0},b={0};
    a.eligible=b.eligible=true; a.pressure=0.0f; b.pressure=1.0f;
    LGLocalButtonPressureUniform pa={0},pb={0};
    assert(LGLocalButtonPressureUniformFromState(&a,132,30,1,&pa));
    assert(LGLocalButtonPressureUniformFromState(&b,132,30,1,&pb));
    assert(pa.bucket==0 && fabsf(pa.thickness-30)<0.001f && fabsf(pa.refractionScale-1)<0.001f);
    assert(pb.bucket==8 && pb.thickness<pa.thickness && pb.refractionScale<pa.refractionScale);
    assert(a.pressure==0.0f && b.pressure==1.0f);
    b.eligible=false;
    assert(!LGLocalButtonPressureUniformFromState(&b,132,30,1,&pb));
    // New boundary tests exercise the actual final production headers.
    c=fixture(); c.immutableUntilFrameReleased=false;
    assert(check(&c,1.0,17,4,6,9,132,132,81,81,true,false)==LGLocalSourceBadContract);
    c=fixture(); c.sampledRGBIsPremultiplied=false;
    assert(check(&c,1.0,17,4,6,9,132,132,81,81,true,false)==LGLocalSourceBadAlpha);
    c=fixture(); c.sampledRGBIsLinear=false;
    assert(check(&c,1.0,17,4,6,9,132,132,81,81,true,false)==LGLocalSourceBadAlpha);
    c=fixture(); LGLocalSourceCursor cursor={0};
    assert(LGLocalSourceAcceptOrder(&cursor,&c));
    assert(LGLocalSourceAcceptOrder(&cursor,&c)); // same immutable frame
    LGLocalSourceCursor prior=cursor;
    c.frameTimestampMonotonic+=.001; // cannot refresh a stale frame's label
    assert(!LGLocalSourceAcceptOrder(&cursor,&c));
    assert(cursor.frameTimestamp==prior.frameTimestamp);
    c=fixture();c.ownerGeneration--;
    assert(!LGLocalSourceAcceptOrder(&cursor,&c));
    c=fixture();c.frameGeneration--;
    assert(!LGLocalSourceAcceptOrder(&cursor,&c));
    c=fixture();c.ownerInstanceToken++;
    assert(!LGLocalSourceAcceptOrder(&cursor,&c));
    c=fixture();c.ownerGeneration++;c.frameGeneration=1;
    assert(LGLocalSourceAcceptOrder(&cursor,&c)); // same owner moves forward
    c=fixture();assert(!LGLocalSourceAcceptOrder(&cursor,&c));
    c=fixture();LGLocalButtonSourceContract copy=c;
    assert(LGLocalSameFrameDescriptor(&c,&copy));
    copy.pointScale=2;assert(!LGLocalSameFrameDescriptor(&c,&copy));
    assert(fabs(LGLocalSourceExpiryDelay(&c,1.05)-.05)<1e-7);
    assert(LGLocalSourceExpiryDelay(&c,1.2)==0);
    LGButtonOpticalState observed={0};observed.eligible=true;observed.geometryGeneration=9;
    LGLocalButtonUniforms idle={0},pressed={0};
    assert(LGLocalButtonBuildUniforms(&c,&observed,132,132,3,false,&idle));
    assert(idle.glassThickness==108 && idle.refractionScale==2);
    assert(fabsf(idle.refractiveIndex-1.6f)<1e-6 && idle.bezelWidth==48);
    assert(idle.tintColor.w==0 && idle.buttonCandidatePointScale==3);
    assert(idle.buttonCandidateRendererScale==3 && idle.radius==66);
    observed.pressure=1;
    assert(LGLocalButtonBuildUniforms(&c,&observed,132,132,3,false,&pressed));
    assert(fabsf(pressed.glassThickness-52.8f)<1e-4 && fabsf(pressed.refractionScale-1.8f)<1e-5);
    observed.pressure=NAN;assert(!LGLocalButtonBuildUniforms(&c,&observed,132,132,3,false,&pressed));
    observed.pressure=0;observed.geometryGeneration=8;
    assert(!LGLocalButtonBuildUniforms(&c,&observed,132,132,3,false,&pressed));
    observed.geometryGeneration=9;c.pointScale=NAN;
    assert(!LGLocalButtonBuildUniforms(&c,&observed,132,132,3,false,&pressed));
    // Source clear must not forget which texture belongs to the last accepted
    // immutable frame. The ObjC caller supplies a zeroing-weak object equality.
    LGLocalButtonSourceContract last=fixture(),repeat=last;
    assert(LGLocalRepeatedFrameIdentityValid(&repeat,&last,true,true));
    assert(!LGLocalRepeatedFrameIdentityValid(&repeat,&last,true,false));
    // Negative control for the former behavior: if sourceFrame=nil erased the
    // remembered identity, this same tuple with another texture was accepted.
    assert(LGLocalRepeatedFrameIdentityValid(&repeat,0,false,false));
    repeat.alphaMode=LGLocalAlphaOpaque;
    assert(!LGLocalRepeatedFrameIdentityValid(&repeat,&last,true,true));
    repeat=last;repeat.frameGeneration++;
    assert(LGLocalRepeatedFrameIdentityValid(&repeat,&last,true,false));
    LGLocalSourceCursor order={0};
    assert(LGLocalSourceAcceptOrder(&order,&last));
    assert(LGLocalSourceAcceptOrder(&order,&repeat));
    assert(!LGLocalSourceAcceptOrder(&order,&last));
    repeat=last;repeat.ownerGeneration++;repeat.frameGeneration=1;
    assert(LGLocalRepeatedFrameIdentityValid(&repeat,&last,true,false));
    assert(LGLocalSourceAcceptOrder(&order,&repeat));
    repeat=last;repeat.frameTimestampMonotonic+=.001;
    assert(!LGLocalRepeatedFrameIdentityValid(&repeat,&last,true,true));
    assert(!LGLocalRepeatedFrameIdentityValid(0,&last,true,true));

    // Explicit finite overscan: source62x62pt, target44x44pt, asymmetric margins.
    c=fixture(); c.sourceRectInOwnerPoints=CGRectMake(2,14,62,62);
    c.targetRectInOwnerPoints=CGRectMake(10,20,44,44);
    c.textureWidth=c.textureHeight=186; c.sourceOverscanEnabled=true;
    assert(check(&c,1.0,17,4,6,9,186,186,81,81,true,false)==LGLocalSourceValid);
    LGLocalButtonSourceLayout layout={0};
    assert(LGLocalSourceLayoutForContract(&c,186,186,&layout));
    assert(layout.leftPaddingPoints==8 && layout.topPaddingPoints==6 &&
           layout.rightPaddingPoints==10 && layout.bottomPaddingPoints==12);
    assert(layout.targetPixelWidth==132 && layout.targetPixelHeight==132);
    LGButtonOpticalState touch={0};touch.eligible=true;touch.geometryGeneration=9;
    touch.phase=LGOpticalTrackingInside;touch.touchValid=true;
    touch.touchX=.25f;touch.touchY=.5f;touch.pressure=.5f;
    LGLocalButtonUniforms wide={0};
    assert(LGLocalButtonBuildUniforms(&c,&touch,132,132,3,true,&wide));
    assert(wide.resolution.x==132 && wide.resolution.y==132);
    assert(wide.outputResolution.x==132 && wide.outputResolution.y==132);
    assert(wide.buttonCandidateMaxOffset<26.0f && wide.buttonCandidateMaxOffset>25.6f);
    assert(wide.buttonSourceOverscanEnabled==1);
    assert(wide.buttonSourceTargetOriginPixels.x==24 &&
           wide.buttonSourceTargetOriginPixels.y==18);
    assert(wide.buttonContactCenter.x==.25f && wide.buttonContactCenter.y==.5f);
    c=fixture();c.sourceOverscanEnabled=true; // opt-in with exact zero padding
    LGLocalButtonUniforms zeroPad={0};
    assert(LGLocalButtonBuildUniforms(&c,&observed,132,132,3,false,&zeroPad));
    assert(zeroPad.buttonSourceOverscanEnabled==0 &&
           zeroPad.buttonSourceTargetOriginPixels.x==0 &&
           zeroPad.buttonSourceTargetOriginPixels.y==0);
    c=fixture();c.sourceRectInOwnerPoints=CGRectMake(2,14,62,62);
    c.targetRectInOwnerPoints=CGRectMake(10,20,44,44);
    c.textureWidth=c.textureHeight=186; // geometry without explicit source opt-in
    assert(check(&c,1.0,17,4,6,9,186,186,81,81,true,false)==LGLocalSourceBadGeometry);
    c.sourceOverscanEnabled=true;
    assert(check(&c,1.0,17,4,6,9,180,186,81,81,true,false)==LGLocalSourceBadGeometry);
    c=fixture();c.sourceOverscanEnabled=true;
    c.sourceRectInOwnerPoints=CGRectMake(-7,20,61,44);
    c.targetRectInOwnerPoints=CGRectMake(10,20,44,44);
    c.textureWidth=183;c.textureHeight=132;
    assert(check(&c,1.0,17,4,6,9,183,132,81,81,true,false)==LGLocalSourceBadGeometry);
    c=fixture();c.sourceOverscanEnabled=true;
    c.sourceRectInOwnerPoints=CGRectMake(11,20,44,44); // target protrudes by 1pt
    assert(check(&c,1.0,17,4,6,9,132,132,81,81,true,false)==LGLocalSourceBadGeometry);
    LGLocalButtonUniforms promoted={0}; uint8_t legacy224[224]={0};
    assert(LGLocalButtonPromoteContactABI224(legacy224,sizeof legacy224,&promoted));
    assert(promoted.buttonContactEnabled==0 && promoted.buttonSourceOverscanEnabled==0 &&
           promoted.buttonSourceTargetOriginPixels.x==0 && promoted.buttonSourceTargetOriginPixels.y==0);
    assert(!LGLocalButtonPromoteContactABI224(legacy224,223,&promoted));
    puts("source cursor, finite ROI overscan, target-local contact mapping, legacy224 promotion, immutable lease/color and ABI: PASS");
    return 0;
}
