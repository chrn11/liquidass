#include "../../Shared/LGButtonMaterialCandidate.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static float len2(float x, float y) { return sqrtf(x*x + y*y); }
static LGButtonOpticsResult eval(float x, float y, float w, float h,
                                 bool enabled, float thickness,
                                 bool contact, float cx, float cy, float p) {
    return LGButtonOpticsEvaluateWithContact(
        x,y,w,h,w*.5f,h*.5f,fminf(w,h)*.25f,16.0f,thickness,1.6f,2.0f,
        16.0f,3.0f,3.0f,enabled,contact,cx,cy,p);
}
static void sameCore(LGButtonOpticsResult a, LGButtonOpticsResult b) {
    assert(a.valid==b.valid);
    assert(a.signedDistance==b.signedDistance);
    assert(a.height==b.height && a.normalX==b.normalX && a.normalY==b.normalY);
    assert(a.offsetX==b.offsetX && a.offsetY==b.offsetY);
    assert(a.sampleU==b.sampleU && a.sampleV==b.sampleV);
    assert(a.environmentU==b.environmentU && a.environmentV==b.environmentV);
    assert(a.environmentWeight==b.environmentWeight);
    assert(a.environmentOffsetX==b.environmentOffsetX && a.environmentOffsetY==b.environmentOffsetY);
}
static void testSmoothLimiter(void) {
    const float cap=16.0f, shoulder=cap*.25f, start=cap-shoulder;
    float last=0.0f;
    for (unsigned i=0;i<=8192;i++) {
        float raw=cap*8.0f*(float)i/8192.0f;
        float got=LGBOSmoothCappedLength(raw,cap);
        assert(isfinite(got) && got>=last && got>=0.0f && got<cap);
        if (raw<=start) assert(fabsf(got-raw)<0.00001f);
        last=got;
    }
    assert(LGBOSmoothCappedLength(0.0f,cap)==0.0f);
    assert(fabsf(LGBOSmoothCappedLength(cap,cap)-cap*.875f)<0.0001f);
    assert(LGBOSmoothCappedLength(1000.0f,cap)<cap);
    assert(LGBOSmoothCappedLength(10.0f,0.0f)==0.0f);
    const float h=cap*0.0001f;
    for (unsigned k=0;k<2;k++) {
        float x=k?cap:start;
        float dl=(LGBOSmoothCappedLength(x,cap)-LGBOSmoothCappedLength(x-h,cap))/h;
        float dr=(LGBOSmoothCappedLength(x+h,cap)-LGBOSmoothCappedLength(x,cap))/h;
        assert(isfinite(dl) && isfinite(dr) && fabsf(dl-dr)<0.01f);
    }
}
static void testIdentityAndContactIsolation(void) {
    const float w=132,h=88,x=92.5f,y=44.5f;
    LGButtonOpticsResult base=eval(x,y,w,h,true,108.0f,false,.7f,.5f,.8f);
    LGButtonOpticsResult zeroContact=eval(x,y,w,h,true,108.0f,true,.7f,.5f,0.0f);
    assert(base.valid && base.signedDistance<0.0f);
    sameCore(base,zeroContact); /* no-contact is unchanged by the contact term only */
    LGButtonOpticsResult contact=eval(x,y,w,h,true,108.0f,true,.7f,.5f,.8f);
    assert(contact.valid && isfinite(contact.height) && isfinite(contact.normalX) && isfinite(contact.normalY));
    assert(contact.height<base.height);
    assert(len2(contact.normalX,contact.normalY)<=1.0f+1e-5f);
    /* Height and contact normal retain the same signed gradient direction. */
    const float e=.25f;
    float gx=(eval(x+e,y,w,h,true,108.0f,true,.7f,.5f,.8f).height-
              eval(x-e,y,w,h,true,108.0f,true,.7f,.5f,.8f).height)/(2.0f*e);
    float gy=(eval(x,y+e,w,h,true,108.0f,true,.7f,.5f,.8f).height-
              eval(x,y-e,w,h,true,108.0f,true,.7f,.5f,.8f).height)/(2.0f*e);
    if (fabsf(gx)>.01f) assert(contact.normalX*gx<0.0f);
    if (fabsf(gy)>.01f) assert(contact.normalY*gy<0.0f);

    LGButtonOpticsResult off=eval(x,y,w,h,false,108.0f,true,.7f,.5f,.8f);
    LGButtonOpticsResult zeroThickness=eval(x,y,w,h,true,0.0f,true,.7f,.5f,.8f);
    LGButtonOpticsResult zeroCap=LGButtonOpticsEvaluateWithContact(x,y,w,h,w*.5f,h*.5f,22,16,108,1.6f,2,0,3,3,true,false,0,0,0);
    LGButtonOpticsResult outside=eval(133.0f,y,w,h,true,108.0f,false,.7f,.5f,0);
    LGButtonOpticsResult ids[]={off,zeroThickness,zeroCap,outside};
    for (unsigned i=0;i<sizeof(ids)/sizeof(ids[0]);i++) {
        LGButtonOpticsResult q=ids[i];
        assert(q.valid);
        assert(q.offsetX==0.0f && q.offsetY==0.0f && q.height==0.0f);
        assert(q.environmentWeight==0.0f && q.environmentOffsetX==0.0f && q.environmentOffsetY==0.0f);
    }
    assert(outside.signedDistance>0.0f);
    assert(fabsf(off.sampleU-LGBOClamp(x,.5f,w-.5f)/w)<1e-6f);
    assert(fabsf(zeroThickness.sampleU-off.sampleU)<1e-6f);
}
static void testOpticalEdgeContinuity(void) {
    const float w=132,h=88,cx=66,cy=44;
    LGButtonOpticsResult inside=LGButtonOpticsEvaluate(cx,87.999f,w,h,cx,cy,22,16,108,1.6f,2,16,3,3,true);
    LGButtonOpticsResult edge=LGButtonOpticsEvaluate(cx,88.0f,w,h,cx,cy,22,16,108,1.6f,2,16,3,3,true);
    LGButtonOpticsResult outside=LGButtonOpticsEvaluate(cx,88.001f,w,h,cx,cy,22,16,108,1.6f,2,16,3,3,true);
    assert(inside.valid && inside.signedDistance<0.0f && edge.valid && fabsf(edge.signedDistance)<1e-5f);
    assert(outside.valid && outside.signedDistance>0.0f);
    assert(inside.height<0.1f && len2(inside.offsetX,inside.offsetY)<0.001f);
    assert(inside.environmentWeight<1e-6f);
    assert(edge.offsetX==0 && edge.offsetY==0 && edge.environmentWeight==0);
    assert(outside.offsetX==0 && outside.offsetY==0 && outside.environmentWeight==0);
}
static void testNaturalGeometrySweeps(void) {
    const float sizes[][3]={{132,88,22},{132,132,66},{264,132,66}};
    for (unsigned c=0;c<sizeof(sizes)/sizeof(sizes[0]);c++) {
        float w=sizes[c][0],h=sizes[c][1],r=sizes[c][2],cap=16.0f;
        for (unsigned iy=1;iy<40;iy++) for (unsigned ix=1;ix<40;ix++) {
            float x=w*(float)ix/40.0f,y=h*(float)iy/40.0f;
            LGButtonOpticsResult q=LGButtonOpticsEvaluate(
                x,y,w,h,w*.5f,h*.5f,r,16,108,1.6f,2,cap,3,3,true);
            assert(q.valid && isfinite(q.height) && isfinite(q.normalX) && isfinite(q.normalY));
            assert(isfinite(q.sampleU) && isfinite(q.sampleV) && isfinite(q.environmentU) && isfinite(q.environmentV));
            assert(isfinite(q.environmentWeight) && q.environmentWeight>=0 && q.environmentWeight<=.28f);
            assert(len2(q.offsetX,q.offsetY)<=cap+1e-5f);
            float envCap=fminf(cap*.45f,fminf(108.0f,fmaxf(16.0f,1.0f))*.38f);
            assert(len2(q.environmentOffsetX,q.environmentOffsetY)<=envCap+1e-5f);
        }
    }
}
static void testLocalMinificationFootprint(void) {
    LGMinificationFootprint identity=LGBOAnalyzeMinificationFootprint(1,0,0,1);
    assert(identity.valid && identity.tapCount==1 && identity.major==1.0f);
    LGMinificationFootprint magnified=LGBOAnalyzeMinificationFootprint(.75f,0,0,.5f);
    assert(magnified.valid && magnified.tapCount==1);

    LGMinificationFootprint compressed=LGBOAnalyzeMinificationFootprint(2,0,0,1);
    assert(compressed.valid && compressed.tapCount==2);
    assert(fabsf(compressed.major-2.0f)<1e-5f && fabsf(compressed.minor-1.0f)<1e-5f);
    assert(fabsf(fabsf(compressed.axisX)-1.0f)<1e-5f && fabsf(compressed.axisY)<1e-5f);
    assert(compressed.filterWidth<=4.0f);

    LGMinificationFootprint diagonal=LGBOAnalyzeMinificationFootprint(2,2,-2,2);
    assert(diagonal.valid && diagonal.tapCount==2);
    assert(fabsf(diagonal.major-sqrtf(8.0f))<1e-4f);
    assert(fabsf(diagonal.minor-sqrtf(8.0f))<1e-4f);

    LGMinificationFootprint four=LGBOAnalyzeMinificationFootprint(8,0,0,1);
    assert(four.valid && four.tapCount==4 && four.major==8.0f);
    assert(four.filterWidth==4.0f); /* explicit bounded support */
    LGMinificationFootprint invalid=LGBOAnalyzeMinificationFootprint(NAN,0,0,1);
    assert(!invalid.valid && invalid.tapCount==1);
}

int main(void) {
    testSmoothLimiter();
    testIdentityAndContactIsolation();
    testOpticalEdgeContinuity();
    testNaturalGeometrySweeps();
    testLocalMinificationFootprint();
    puts("PASS natural-volume and bounded minification numerics; compile/run on macOS only");
    return 0;
}
