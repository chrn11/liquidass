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
            assert(q.environmentWeight==0.0f);
            assert(q.environmentOffsetX==q.offsetX && q.environmentOffsetY==q.offsetY);
            assert(q.environmentU==q.sampleU && q.environmentV==q.sampleV);
        }
    }
}
static void testLocalMinificationFootprint(void) {
    LGMinificationFootprint identity=LGBOAnalyzeMinificationFootprint(1,0,0,1);
    assert(identity.valid && identity.tapCount==1 && identity.major==1.0f);
    LGMinificationFootprint magnified=LGBOAnalyzeMinificationFootprint(.75f,0,0,.5f);
    assert(magnified.valid && magnified.tapCount==1);

    LGMinificationFootprint compressed=LGBOAnalyzeMinificationFootprint(2,0,0,1);
    assert(compressed.valid && compressed.tapCount==4);
    assert(fabsf(compressed.major-2.0f)<1e-5f && fabsf(compressed.minor-1.0f)<1e-5f);
    assert(fabsf(compressed.kernelXX*compressed.kernelXX-.05f)<1e-6f);
    assert(compressed.kernelXY==0 && compressed.kernelYY==0);
    assert(compressed.filterWidth<=4.0f);

    LGMinificationFootprint diagonal=LGBOAnalyzeMinificationFootprint(2,2,-2,2);
    // singular values are sqrt(8), above the explicit2.5 four-tap boundary.
    assert(diagonal.valid && diagonal.tapCount==4);
    assert(fabsf(diagonal.major-sqrtf(8.0f))<1e-4f);
    assert(fabsf(diagonal.minor-sqrtf(8.0f))<1e-4f);

    LGMinificationFootprint four=LGBOAnalyzeMinificationFootprint(8,0,0,1);
    assert(four.valid && four.tapCount==4 && four.major==8.0f);
    assert(four.filterWidth==4.0f); /* explicit bounded support */
    LGMinificationFootprint invalid=LGBOAnalyzeMinificationFootprint(NAN,0,0,1);
    assert(!invalid.valid && invalid.tapCount==1);
    assert(fabsf(diagonal.kernelXX-diagonal.kernelYY)<1e-6f && diagonal.kernelXY==0);
    assert(fabsf(diagonal.kernelXX*diagonal.kernelXX-7.0f/60.0f)<1e-6f);
    assert(fabsf(four.kernelXX-.5f)<1e-6f && four.kernelYY==0);
    // The kernel must vanish at unit footprint and have no special2.5 split.
    const float boundaries[]={1.0f,1.001f,1.25f,2.5f,4.0f};
    for(unsigned i=0;i<5;i++) {
        float t=boundaries[i];
        LGMinificationFootprint lo=LGBOAnalyzeMinificationFootprint(t-.0001f,0,0,1);
        LGMinificationFootprint hi=LGBOAnalyzeMinificationFootprint(t+.0001f,0,0,1);
        assert(lo.valid&&hi.valid&&fabsf(lo.kernelXX-hi.kernelXX)<.001f);
    }
    LGMinificationFootprint sx=LGBOAnalyzeMinificationFootprint(2.00001f,0,0,1.99999f);
    LGMinificationFootprint sy=LGBOAnalyzeMinificationFootprint(1.99999f,0,0,2.00001f);
    assert(fabsf(sx.kernelXX-sy.kernelXX)<.001f && fabsf(sx.kernelYY-sy.kernelYY)<.001f);
    // Tap-center radius <=sqrt(2.5), independent of arbitrary SVD axis signs.
    for(int i=-8;i<=8;i++)for(int j=-8;j<=8;j++) {
        LGMinificationFootprint q=LGBOAnalyzeMinificationFootprint((float)i,.3f,-.2f,(float)j);
        assert(q.valid);
        float ax=3*q.kernelXX+q.kernelXY,ay=3*q.kernelXY+q.kernelYY;
        float bx=q.kernelXX-3*q.kernelXY,by=q.kernelXY-3*q.kernelYY;
        assert(ax*ax+ay*ay<=2.5001f && bx*bx+by*by<=2.5001f);
    }
}

static void testFiniteSphericalCap(void) {
    const float R=66.0f,B=48.0f,Rc=sqrtf(R*R+B*B);
    const float sag=R*R/(Rc+B);
    LGButtonOpticsResult middle=LGButtonOpticsEvaluate(66,66,132,132,66,66,66,48,108,1.6f,2,132*7.0f/36.0f,3,3,true);
    assert(middle.valid&&fabsf(middle.height-sag)<1e-4f);
    assert(middle.offsetX==0&&middle.offsetY==0&&middle.environmentWeight==0);
    LGButtonOpticsResult press=LGButtonOpticsEvaluate(66,66,132,132,66,66,66,48,52.8f,1.6f,1.8f,132*7.0f/36.0f,3,3,true);
    assert(fabsf(press.height-sag*.8f)<1e-4f);
    float previous=0;
    for(unsigned i=1;i<660;i++) {
        float x=132.0f-i*.1f;
        LGButtonOpticsResult q=LGButtonOpticsEvaluate(x,66,132,132,66,66,66,48,108,1.6f,2,132*7.0f/36.0f,3,3,true);
        assert(q.valid&&q.height>=previous-1e-4f&&q.height<=sag+1e-4f);previous=q.height;
        float normalZ=sqrtf(fmaxf(0,1-q.normalX*q.normalX-q.normalY*q.normalY));
        float depth=132.0f-x;
        if(depth>=4.5f) {
            assert(normalZ>=B/Rc-1e-5f); // unchanged inner spherical-cap bound
        } else {
            const float b=4.5f;
            float rootAtJoin=sqrtf(B*B+R*R*(b/R)*(2.0f-b/R));
            float hb=R*R*(b/R)*(2.0f-b/R)/(rootAtJoin+B);
            // Cubic endpoint interpolation has slope <=1.5*hb/b for0<=q<=1.
            float maximumSlope=1.5f*hb/b;
            assert(normalZ>=1.0f/sqrtf(1.0f+maximumSlope*maximumSlope)-1e-5f);
        }
        // The exact lip join is C1; the dedicated lip test checks both sides.
        if(i>2&&i<658&&fabsf(depth-4.5f)>.051f) {
            const float e=.05f;
            LGButtonOpticsResult a=LGButtonOpticsEvaluate(x-e,66,132,132,66,66,66,48,108,1.6f,2,132*7.0f/36.0f,3,3,true);
            LGButtonOpticsResult b=LGButtonOpticsEvaluate(x+e,66,132,132,66,66,66,48,108,1.6f,2,132*7.0f/36.0f,3,3,true);
            assert(fabsf(q.normalX/normalZ+(b.height-a.height)/(2*e))<.001f);
        }
    }
    for(int y=1;y<132;y++)for(int x=1;x<132;x++) {
        LGButtonOpticsResult q=LGButtonOpticsEvaluateWithContact(x,y,132,132,66,66,66,48,108,1.6f,2,132*7.0f/36.0f,3,3,true,true,.06f,.5f,1);
        assert(q.valid&&q.height>=-1e-5f&&q.height<=sag+1e-4f);
    }
}
int main(void) {
    testFiniteSphericalCap();
    testSmoothLimiter();
    testIdentityAndContactIsolation();
    testOpticalEdgeContinuity();
    testNaturalGeometrySweeps();
    testLocalMinificationFootprint();
    puts("PASS natural-volume and bounded minification numerics; compile/run on macOS only");
    return 0;
}
