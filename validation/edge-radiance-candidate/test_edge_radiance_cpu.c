/* Numerical source contract for candidate-only image-driven edge radiance.
 * Build this C file only with the macOS clang runner; never with iSH/Linux. */
#include "LGButtonMaterialCandidate.h"
#include <math.h>
#include <stdio.h>

#define REQUIRE(c, message) do { \
    if (!(c)) { fprintf(stderr, "FAIL: %s (%s:%d)\n", message, __FILE__, __LINE__); return 1; } \
} while (0)

static LGButtonOpticsResult evaluate(float x, bool contact, float pressure) {
    return LGButtonOpticsEvaluateWithContact(
        x,66.0f,132.0f,132.0f,66.0f,66.0f,66.0f,48.0f,
        108.0f,1.6f,2.0f,132.0f*7.0f/36.0f,3.0f,3.0f,true,
        contact,0.92f,0.50f,pressure);
}

static float radianceField(float x, float y) {
    float value=0.22f+0.0012f*x+0.0007f*y;
    return LGBOClamp(value,0.0f,1.0f);
}

static float modeledOutput(float x, float pressure) {
    LGButtonOpticsResult q=evaluate(x,true,pressure);
    float n=LGBOHypot(q.normalX,q.normalY);
    float nx=n>0.0001f?q.normalX/n:1.0f;
    float ny=n>0.0001f?q.normalY/n:0.0f;
    float radius=LGBOImageEdgeRadianceRadius(q.height,3.0f);
    float cx=x+q.offsetX, cy=66.0f+q.offsetY;
    float a=radianceField(cx+radius*nx,cy+radius*ny);
    float b=radianceField(cx-radius*nx,cy-radius*ny);
    float c=radianceField(cx-radius*ny,cy+radius*nx);
    float d=radianceField(cx+radius*ny,cy-radius*nx);
    float integral=LGBOAverageFourRadianceSamples(a,b,c,d);
    float weight=LGBOImageEdgeRadianceWeight(q,132.0f,132.0f,48.0f,3.0f,1.6f,true,true);
    return LGBOEnvironmentMixPremultipliedChannel(
        radianceField(cx,cy),1.0f,integral,1.0f,weight);
}

static int testUniformIdentityAndQuadrature(void) {
    const float levels[]={0.0f,0.23f,0.5f,1.0f};
    LGButtonOpticsResult edge=evaluate(130.0f,false,0.0f); //inside new1.5pt lip
    float weight=LGBOImageEdgeRadianceWeight(edge,132,132,48,3,1.6f,true,true);
    REQUIRE(weight>0.0f && weight<=0.28f,"candidate edge weight must be finite and bounded");
    REQUIRE(edge.environmentWeight==0.0f,"base optics API must retain zero environment weight");
    for (unsigned i=0;i<sizeof(levels)/sizeof(levels[0]);i++) {
        float v=levels[i], alpha=0.65f;
        float average=LGBOAverageFourRadianceSamples(v,v,v,v);
        float output=LGBOEnvironmentMixPremultipliedChannel(
            v*alpha,alpha,average*alpha,alpha,weight);
        REQUIRE(fabsf(average-v)<1.0e-7f,"four-tap quadrature preserves constant radiance");
        REQUIRE(fabsf(output-v*alpha)<1.0e-6f,"uniform black/gray/white remain identical");
    }
    REQUIRE(LGBOAverageFourRadianceSamples(0.0f,0.25f,0.5f,1.0f)==0.4375f,
            "four equal positive quadrature weights sum to one");
    return 0;
}

static int testSourceEnergyAndBoundaries(void) {
    float tap[4]={0.08f,0.31f,0.62f,0.91f};
    float integral=LGBOAverageFourRadianceSamples(tap[0],tap[1],tap[2],tap[3]);
    LGButtonOpticsResult edge=evaluate(130.0f,false,0.0f); //inside new1.5pt lip
    float w=LGBOImageEdgeRadianceWeight(edge,132,132,48,3,1.6f,true,true);
    float output=LGBOEnvironmentMixPremultipliedChannel(0.17f,1.0f,integral,1.0f,w);
    float lo=0.08f,hi=0.91f;
    REQUIRE(output>=lo-1.0e-6f && output<=hi+1.0e-6f,
            "passive convex mix cannot exceed captured source range");
    REQUIRE(LGBOImageEdgeRadianceRadius(edge.height,3.0f)<=48.0f+1.0e-5f,
            "cone support never exceeds 16 points at 3x");
    REQUIRE(LGBOImageEdgeRadianceRadius(0.0f,3.0f)==0.0f,
            "zero height has zero source support");
    REQUIRE(LGBOImageEdgeRadianceWeight(edge,132,132,48,3,1.6f,true,false)==0.0f,
            "missing explicit overscan lease disables edge cue");
    REQUIRE(LGBOImageEdgeRadianceWeight(edge,132,132,48,3,1.6f,false,true)==0.0f,
            "optics-off disables edge cue");
    REQUIRE(LGBOImageEdgeRadianceWeight(edge,132,132,48,3,1.0f,true,true)==0.0f,
            "unit-index no-optics case disables edge cue");
    REQUIRE(LGBOImageEdgeRadianceWeight(edge,132,132,48,3,1.6f,true,true)<=0.28f,
            "edge mix respects established passive mix ceiling");
    LGButtonOpticsResult outside=evaluate(133.0f,false,0.0f);
    REQUIRE(LGBOImageEdgeRadianceWeight(outside,132,132,48,3,1.6f,true,true)==0.0f,
            "shape exterior has zero radiance weight");
    LGButtonOpticsResult middle=LGButtonOpticsEvaluateWithContact(
        66,66,132,132,66,66,66,48,108,1.6f,2,132.0f*7/36,3,3,true,
        false,0,0,0);
    REQUIRE(LGBOImageEdgeRadianceWeight(middle,132,132,48,3,1.6f,true,true)==0.0f,
            "edge window vanishes in the interior");
    REQUIRE(LGBOEnvironmentMixPremultipliedChannel(0.13f,1.0f,0.99f,1.0f,0.0f)==0.13f,
            "zero/off path is bit-preserving for transmitted source");
    return 0;
}

static int testTouchContinuity(void) {
    float baseline=modeledOutput(130.0f,0.0f);
    float tiny=modeledOutput(130.0f,0.00001f);
    REQUIRE(isfinite(baseline) && isfinite(tiny) && fabsf(baseline-tiny)<3.0e-4f,
            "touch enable at zero pressure is continuous");
    float left=modeledOutput(130.0f,0.5f-0.0001f);
    float right=modeledOutput(130.0f,0.5f+0.0001f);
    REQUIRE(isfinite(left) && isfinite(right) && fabsf(left-right)<3.0e-4f,
            "image-driven cue remains continuous across touch pressure");
    for (int i=0;i<=20;i++) {
        float p=(float)i/20.0f;
        float value=modeledOutput(130.0f,p);
        REQUIRE(isfinite(value) && value>=0.0f && value<=1.0f,
                "all touch pressures remain finite and bounded");
    }
    return 0;
}

int main(void) {
    if (testUniformIdentityAndQuadrature()) return 1;
    if (testSourceEnergyAndBoundaries()) return 1;
    if (testTouchContinuity()) return 1;
    puts("PASS: edge radiance C source contract");
    return 0;
}
