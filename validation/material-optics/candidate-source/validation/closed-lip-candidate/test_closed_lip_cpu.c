/* Closed-lip geometry regression. Compile only with Apple's macOS clang runner. */
#include "LGButtonMaterialCandidate.h"
#include <math.h>
#include <stdio.h>
#include "frozen_parent_cpu.h"

#define REQUIRE(c, m) do { if (!(c)) { fprintf(stderr,"FAIL: %s (%d)\n",m,__LINE__); return 1; } } while (0)

static LGButtonOpticsResult atDepth(float depth, bool contact, float pressure) {
    return LGButtonOpticsEvaluateWithContact(
        132.0f-depth,66.0f,132.0f,132.0f,66.0f,66.0f,66.0f,48.0f,
        108.0f,1.6f,2.0f,132.0f*7.0f/36.0f,3.0f,3.0f,true,
        contact,0.95f,0.50f,pressure);
}

static float oldCapHeight(float depth) {
    const float R=66.0f, B=48.0f, T=108.0f;
    float t=LGBOClamp(depth/R,0.0f,1.0f);
    float sag=R*R/(LGBOHypot(R,B)+B);
    float root=sqrtf(B*B+R*R*t*(2.0f-t));
    float rise=R*R*t*(2.0f-t)/(root+B);
    float amplitude=fminf(R,T)*(sag/R);
    return amplitude*(rise/sag);
}

static float oldCapSlope(float depth) {
    const float R=66.0f, B=48.0f, T=108.0f;
    float t=LGBOClamp(depth/R,0.0f,1.0f);
    float sag=R*R/(LGBOHypot(R,B)+B);
    float root=sqrtf(B*B+R*R*t*(2.0f-t));
    float amplitude=fminf(R,T)*(sag/R);
    return amplitude*(R*(1.0f-t)/(root*sag));
}

static float surfaceDepthSlope(LGButtonOpticsResult q) {
    float nz=sqrtf(fmaxf(1.0f-q.normalX*q.normalX-q.normalY*q.normalY,0.0f));
    return nz>1.0e-6f ? q.normalX/nz : NAN;
}

static int testProfileAndCapJoin(void) {
    const float b=4.5f;
    LGButtonOpticsResult edge=atDepth(0.0f,false,0.0f);
    REQUIRE(edge.valid && edge.height==0.0f && edge.normalX==0.0f && edge.normalY==0.0f,
            "closed boundary is zero-height with finite tangent normal");
    float prev=edge.height;
    for (int i=1;i<=450;i++) {
        float d=(float)i*0.01f;
        LGButtonOpticsResult q=atDepth(d,false,0.0f);
        REQUIRE(q.valid && isfinite(q.height) && q.height>=prev,
                "rolled profile is finite, nonnegative and monotone");
        REQUIRE(isfinite(q.normalX) && isfinite(q.normalY),"lip normal remains finite");
        prev=q.height;
    }
    float eps=0.001f;
    LGButtonOpticsResult left=atDepth(b-eps,false,0.0f);
    LGButtonOpticsResult join=atDepth(b,false,0.0f);
    LGButtonOpticsResult right=atDepth(b+eps,false,0.0f);
    REQUIRE(fabsf(join.height-oldCapHeight(b))<2.0e-5f,
            "join height is exactly the original cap value");
    REQUIRE(oldCapHeight(b+2.0f)>join.height,
            "original cap rises inward from the join");
    REQUIRE(fabsf(surfaceDepthSlope(join)-oldCapSlope(b))<2.0e-4f,
            "join slope matches the original finite-cap derivative");
    REQUIRE(fabsf(surfaceDepthSlope(left)-surfaceDepthSlope(right))<0.004f,
            "normal is C1-continuous through the join");
    REQUIRE(fabsf(left.height-right.height)<0.004f,
            "height is continuous through the join");
    for (int i=0;i<=660;i++) {
        float d=(float)i*0.1f;
        LGButtonOpticsResult q=atDepth(d,false,0.0f);
        if (d>=b) REQUIRE(fabsf(q.height-oldCapHeight(d))<3.0e-5f,
                          "cap height and slope domain are unchanged inside");
    }
    float previousMapped=132.0f;
    float previousPressedMapped=132.0f;
    for (int i=1;i<=660;i++) {
        float d=(float)i*0.1f;
        LGButtonOpticsResult idle=atDepth(d,false,0.0f);
        LGButtonOpticsResult pressed=atDepth(d,true,0.8f);
        float mapped=132.0f-d+idle.offsetX;
        float pressedMapped=132.0f-d+pressed.offsetX;
        REQUIRE(mapped<previousMapped && pressedMapped<previousPressedMapped,
                "default radial source mapping has no lip fold at idle or press");
        previousMapped=mapped;
        previousPressedMapped=pressedMapped;
    }
    return 0;
}

static int testSameHeightGradient(void) {
    const float depths[]={0.08f,0.4f,1.2f,3.0f,4.499f,4.5f,4.501f,8.0f};
    for (unsigned i=0;i<sizeof(depths)/sizeof(depths[0]);i++) {
        float d=depths[i],step=0.001f;
        LGButtonOpticsResult q=atDepth(d,false,0.0f);
        LGButtonOpticsResult p=atDepth(d-step,false,0.0f);
        LGButtonOpticsResult m=atDepth(d+step,false,0.0f);
        float numeric=(m.height-p.height)/(2.0f*step);
        REQUIRE(isfinite(numeric) && fabsf(surfaceDepthSlope(q)-numeric)<0.015f,
                "normal is the derivative of the same height profile");
    }
    return 0;
}

static int testContactAndIdentityEdges(void) {
    for (int i=1;i<=450;i++) {
        float d=(float)i*0.01f;
        LGButtonOpticsResult q=atDepth(d,true,0.8f);
        REQUIRE(q.valid && isfinite(q.height) && q.height>=0.0f &&
                isfinite(q.normalX) && isfinite(q.normalY),
                "pressure dent remains nonnegative with finite same-source normal");
    }
    float d=1.8f,step=0.002f;
    LGButtonOpticsResult q=atDepth(d,true,0.8f);
    LGButtonOpticsResult p=atDepth(d-step,true,0.8f);
    LGButtonOpticsResult m=atDepth(d+step,true,0.8f);
    float numeric=(m.height-p.height)/(2.0f*step);
    REQUIRE(fabsf(surfaceDepthSlope(q)-numeric)<0.04f,
            "contact normal matches the differentiated new height");
    LGButtonOpticsResult a=atDepth(2.0f,false,0.0f);
    LGButtonOpticsResult z=atDepth(2.0f,true,0.0f);
    REQUIRE(a.height==z.height && a.normalX==z.normalX && a.normalY==z.normalY &&
            a.offsetX==z.offsetX && a.offsetY==z.offsetY,
            "zero pressure is exact identity");
    REQUIRE(LGBOImageEdgeRadianceWeight(atDepth(2.0f,false,0.0f),132,132,48,3,1.6f,true,true)>0.0f,
            "same-geometry edge cue has coverage inside the lip");
    REQUIRE(LGBOImageEdgeRadianceWeight(atDepth(4.6f,false,0.0f),132,132,48,3,1.6f,true,true)==0.0f,
            "edge cue is zero outside its geometric lip width");
    LGButtonOpticsResult zeroT=LGButtonOpticsEvaluateWithContact(
        130,66,132,132,66,66,66,48,0,1.6f,2,132.0f*7/36,3,3,true,
        true,0.95f,0.5f,1.0f);
    REQUIRE(zeroT.valid && zeroT.height==0.0f && zeroT.offsetX==0.0f &&
            zeroT.offsetY==0.0f && zeroT.normalX==0.0f && zeroT.normalY==0.0f,
            "zero thickness remains exact optical identity");
    LGButtonOpticsResult off=LGButtonOpticsEvaluateWithContact(
        130,66,132,132,66,66,66,48,108,1.6f,2,132.0f*7/36,3,3,false,
        false,0,0,0);
    REQUIRE(off.valid && off.height==0.0f && off.offsetX==0.0f && off.offsetY==0.0f,
            "optics-off path remains identity");
    LGButtonOpticsResult tiny=LGButtonOpticsEvaluateWithContact(
        0.9999f,0.5f,1.0f,1.0f,0.5f,0.5f,0.5f,0.0f,1.0e-5f,
        1.6f,1.0f,0.05f,0.5f,0.5f,true,false,0,0,0);
    REQUIRE(tiny.valid && isfinite(tiny.height) && tiny.height>=0.0f &&
            isfinite(tiny.normalX) && isfinite(tiny.normalY),
            "tiny valid geometry remains finite and nonnegative");
    LGButtonOpticsResult bad=atDepth(NAN,false,0.0f);
    REQUIRE(!bad.valid,"invalid coordinate remains rejected");
    return 0;
}

static int testInnerSameFrozenParentAndRawQ(void) {
 const float scales[]={.5f,1,2,3,4};
 const float radii[]={.5f,1,22,66};
 const float thicknesses[]={1e-4f,.25f,52.8f,108};
 for(unsigned a=0;a<5;a++)for(unsigned b=0;b<4;b++)for(unsigned z=0;z<4;z++) {
  float r=radii[b],scale=scales[a],bezel=16*scale,lip=fminf(1.5f*scale,r);
  float base=fmaxf(bezel,1.5f*scale),t=lip/r,root=sqrtf(base*base+r*r*t*(2-t));
  float hb=r*r*t*(2-t)/(root+base),mb=r*(1-t)/root;
  float rawQ=lip*mb/hb;
  REQUIRE(isfinite(rawQ)&&rawQ>=0&&rawQ<=1.000002f,"unclamped join ratio must satisfy analytic bounds, not hidden by clip");
  for(unsigned i=0;i<17;i++)for(unsigned contact=0;contact<2;contact++) {
   float depth=lip+(r-lip)*i/16.0f,x=2*r-depth;
   LGButtonOpticsResult n=LGButtonOpticsEvaluateWithContact(x,r,2*r,2*r,r,r,r,bezel,thicknesses[z],1.6f,2,2*r*7/36,scale,scale,true,contact,.9f,.5f,.8f);
   Frozen_LGButtonOpticsResult p=Frozen_LGButtonOpticsEvaluateWithContact(x,r,2*r,2*r,r,r,r,bezel,thicknesses[z],1.6f,2,2*r*7/36,scale,scale,true,contact,.9f,.5f,.8f);
   REQUIRE(n.valid==p.valid && n.height==p.height && n.normalX==p.normalX && n.normalY==p.normalY && n.offsetX==p.offsetX && n.offsetY==p.offsetY,"inner cap and contact/primary displacement exactly match frozen parent");
  }
 }
 return 0;
}

int main(void) {
    if(testInnerSameFrozenParentAndRawQ())return 1;
    if (testProfileAndCapJoin() || testSameHeightGradient() || testContactAndIdentityEdges()) return 1;
    puts("PASS closed-lip C geometry contract; no Metal/GPU claim");
    return 0;
}
