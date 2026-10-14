#include "../Shared/LGButtonMaterialCandidate.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static float length2(float x, float y) { return sqrtf(x * x + y * y); }

static void testEligibilityAndIsolation(void) {
    assert(!LGButtonCandidateIsEligible(false, true, true, true, true, true));
    assert(!LGButtonCandidateIsEligible(true, false, true, true, true, true));
    assert(!LGButtonCandidateIsEligible(true, true, false, true, true, true));
    assert(!LGButtonCandidateIsEligible(true, true, true, false, true, true));
    assert(!LGButtonCandidateIsEligible(true, true, true, true, false, true));
    assert(!LGButtonCandidateIsEligible(true, true, true, true, true, false));
    assert(LGButtonCandidateIsEligible(true, true, true, true, true, true));
    LGButtonCandidateInstanceState first = { false }, second = { false };
    assert(LGButtonCandidateUpdateInstanceState(&first, true));
    assert(first.active && !second.active);
    assert(!LGButtonCandidateUpdateInstanceState(&first, true));
    assert(LGButtonCandidateUpdateInstanceState(&second, true));
    assert(first.active && second.active);
    assert(LGButtonCandidateUpdateInstanceState(&first, false));
    assert(!first.active && second.active);
    assert(LGButtonCandidateUpdateInstanceState(&second, false));
    assert(!first.active && !second.active);
    assert(!LGButtonCandidateUpdateInstanceState(NULL, true));
}

static void testGeometryScales(void) {
    const float scales[] = {0.5f, 1.0f, 1.5f, 2.0f, 3.0f, 4.0f};
    for (unsigned i = 0; i < sizeof(scales) / sizeof(scales[0]); ++i) {
        float p = scales[i];
        float side = LG_BUTTON_CANDIDATE_VIEW_SIZE_POINTS * p;
        LGButtonOpticsGeometry g = {};
        assert(LGButtonCandidateBuildGeometry(side, side, side, side,
                                               p, &g));
        assert(fabsf(g.pointScaleX - p) < 0.0001f);
        assert(fabsf(g.pointScaleY - p) < 0.0001f);
        assert(fabsf(g.centerX - side * 0.5f) < 0.0001f);
        assert(fabsf(g.centerY - side * 0.5f) < 0.0001f);
        assert(fabsf(g.cornerRadius - side * 0.5f) < 0.0001f);
        assert(fabsf(LGButtonCandidateMaxDisplacement(side, side) -
                     side * 7.0f / 36.0f) < 0.001f);
        LGButtonOpticsResult field = LGButtonOpticsEvaluate(
            side * 0.75f, side * 0.5f, side, side, side * 0.5f,
            side * 0.5f, side * 0.5f, 16.0f * p, side * 0.5f,
            1.6f, 2.0f, LGButtonCandidateMaxDisplacement(side, side),
            p, p, true);
        assert(field.valid && field.signedDistance < 0.0f);
        assert(isfinite(field.height) && isfinite(field.normalX) &&
               isfinite(field.normalY));
        assert(length2(field.offsetX, field.offsetY) > 0.001f);
        assert(length2(field.offsetX, field.offsetY) <=
               LGButtonCandidateMaxDisplacement(side, side) + 0.001f);
    }
    LGButtonOpticsGeometry padded = {};
    assert(LGButtonCandidateBuildGeometry(132, 132, 133, 131, 1.5f, &padded));
    assert(padded.sourceWidth == 132 && padded.destinationWidth == 133);
    assert(!LGButtonCandidateBuildGeometry(132, 132, 136, 132, 1.5f, &padded));
    assert(!LGButtonCandidateBuildGeometry(132, 132, 132, 132, NAN, &padded));
    assert(!LGButtonCandidateBuildGeometry(0, 132, 0, 132, 1.5f, &padded));
    assert(!LGButtonCandidateBuildGeometry(132, 132, 132, 132, 5.0f, &padded));
    assert(!LGButtonCandidateBuildGeometry(132, 100, 132, 100, 1.5f, &padded));
    assert(!LGButtonCandidateGeometryValid(INFINITY, 20, 1.0f, 0));
    assert(LGButtonCandidateMaxDisplacement(INFINITY, 20) == 0.0f);
}

static LGButtonOpticsResult evaluate(float x, float y, float w, float h,
                                     float radius, float bezel,
                                     float thickness, float ior,
                                     float refractScale, bool enabled) {
    return LGButtonOpticsEvaluate(x, y, w, h, w * 0.5f, h * 0.5f,
                                  radius, bezel, thickness, ior,
                                  refractScale,
                                  LGButtonCandidateMaxDisplacement(w, h),
                                  fminf(w, h) / 44.0f, 1.5f, enabled);
}

static void testRoundAndCapsuleFields(void) {
    LGButtonOpticsResult center = evaluate(66, 66, 132, 132, 66, 48,
                                            108, 1.6f, 2.0f, true);
    LGButtonOpticsResult shoulder = evaluate(99, 66, 132, 132, 66, 48,
                                              108, 1.6f, 2.0f, true);
    assert(center.valid && shoulder.valid && center.signedDistance < 0);
    assert(center.height > shoulder.height);
    assert(length2(center.offsetX, center.offsetY) < 0.0001f);
    assert(length2(shoulder.offsetX, shoulder.offsetY) > 0.05f);
    assert(length2(shoulder.offsetX, shoulder.offsetY) <=
           LGButtonCandidateMaxDisplacement(132, 132) + 0.001f);

    // Rounded capsule, same field code and local-coordinate contract.
    LGButtonOpticsResult capsule = LGButtonOpticsEvaluate(
        198, 66, 264, 132, 132, 66, 66, 48, 108, 1.6f, 2.0f,
        LGButtonCandidateMaxDisplacement(264, 132), 3.0f, 1.5f, true);
    assert(capsule.valid && capsule.signedDistance < 0);
    assert(length2(capsule.offsetX, capsule.offsetY) > 0.05f);
    assert(length2(capsule.offsetX, capsule.offsetY) <=
           LGButtonCandidateMaxDisplacement(264, 132) + 0.001f);
}

static void testBoundaryContinuityAndIdentity(void) {
    const float w = 132, h = 88, radius = 22, cx = 66, cy = 44;
    LGButtonOpticsResult justInside = LGButtonOpticsEvaluate(
        cx, 87.99f, w, h, cx, cy, radius, 48, 108, 1.6f, 2.0f,
        LGButtonCandidateMaxDisplacement(w, h), 3.0f, 1.5f, true);
    LGButtonOpticsResult atBoundary = LGButtonOpticsEvaluate(
        cx, 88.0f, w, h, cx, cy, radius, 48, 108, 1.6f, 2.0f,
        LGButtonCandidateMaxDisplacement(w, h), 3.0f, 1.5f, true);
    LGButtonOpticsResult justOutside = LGButtonOpticsEvaluate(
        cx, 88.01f, w, h, cx, cy, radius, 48, 108, 1.6f, 2.0f,
        LGButtonCandidateMaxDisplacement(w, h), 3.0f, 1.5f, true);
    assert(justInside.valid && justInside.signedDistance < 0);
    assert(atBoundary.valid && fabsf(atBoundary.signedDistance) < 0.0001f);
    assert(justOutside.valid && justOutside.signedDistance > 0);
    assert(length2(justInside.offsetX, justInside.offsetY) < 0.001f);
    assert(length2(atBoundary.offsetX, atBoundary.offsetY) == 0.0f);
    assert(length2(justOutside.offsetX, justOutside.offsetY) == 0.0f);

    LGButtonOpticsResult disabled = evaluate(99, 66, 132, 132, 66, 48,
                                               108, 1.6f, 2.0f, false);
    LGButtonOpticsResult zeroThickness = evaluate(99, 66, 132, 132, 66, 48,
                                                    0, 1.6f, 2.0f, true);
    assert(disabled.valid && disabled.offsetX == 0 && disabled.offsetY == 0);
    assert(zeroThickness.valid && zeroThickness.offsetX == 0 &&
           zeroThickness.offsetY == 0);
    LGButtonOpticsResult enabled = evaluate(99, 66, 132, 132, 66, 48,
                                              108, 1.6f, 2.0f, true);
    assert(fabsf(disabled.signedDistance - enabled.signedDistance) < 0.0001f);
    assert(disabled.height == 0.0f && zeroThickness.height == 0.0f);
    assert(fabsf(disabled.sampleU - 99.0f / 132.0f) < 0.0001f);
    assert(fabsf(disabled.sampleV - 0.5f) < 0.0001f);
    assert(fabsf(zeroThickness.sampleU - disabled.sampleU) < 0.0001f);
    assert(fabsf(zeroThickness.sampleV - disabled.sampleV) < 0.0001f);
}

static void testFiniteUVAndFallback(void) {
    const float halfX = 0.5f / 132.0f;
    const float halfY = 0.5f / 132.0f;
    LGButtonOpticsResult atLeft = LGButtonOpticsEvaluate(
        0.5f, 66.0f, 132.0f, 132.0f, 66.0f, 66.0f, 66.0f, 48.0f,
        108.0f, 1.6f, 2.0f, LGButtonCandidateMaxDisplacement(132, 132),
        3.0f, 1.5f, true);
    LGButtonOpticsResult atBottom = LGButtonOpticsEvaluate(
        66.0f, 0.5f, 132.0f, 132.0f, 66.0f, 66.0f, 66.0f, 48.0f,
        108.0f, 1.6f, 2.0f, LGButtonCandidateMaxDisplacement(132, 132),
        3.0f, 1.5f, true);
    assert(atLeft.valid && atBottom.valid);
    assert(atLeft.sampleU >= halfX && atLeft.sampleU <= 1.0f - halfX);
    assert(atLeft.sampleV >= halfY && atLeft.sampleV <= 1.0f - halfY);
    assert(atBottom.sampleU >= halfX && atBottom.sampleU <= 1.0f - halfX);
    assert(atBottom.sampleV >= halfY && atBottom.sampleV <= 1.0f - halfY);
    assert(isfinite(atLeft.sampleU) && isfinite(atLeft.sampleV));
    assert(length2(atLeft.offsetX, atLeft.offsetY) <=
           LGButtonCandidateMaxDisplacement(132, 132) + 0.001f);
    LGButtonOpticsResult invalid = LGButtonOpticsEvaluate(
        NAN, 10, 132, 132, 66, 66, 66, 48, 108, 1.6f, 2.0f,
        25, 3.0f, 1.5f, true);
    assert(!invalid.valid);
    invalid = LGButtonOpticsEvaluate(66, 66, 0, 132, 66, 66, 0, 48,
                                     108, 1.6f, 2.0f, 25, 3.0f, 1.5f, true);
    assert(!invalid.valid);
    assert(LGButtonCandidateFormatsCompatible(true, 80, 80));
    assert(!LGButtonCandidateFormatsCompatible(true, 80, 81));
    assert(LGButtonCandidateFormatsCompatible(false, 80, 81));
    assert(!LGButtonCandidateFormatsCompatible(true, 0, 0));
}

static void testEnvironmentRasterContract(void) {
    const float cases[][3] = {{22,22,11},{44,44,22},{66,66,33},{88,88,44},
                              {132,132,66},{176,176,88},{264,132,66},{132,88,22}};
    for (unsigned ci = 0; ci < sizeof(cases)/sizeof(cases[0]); ++ci) {
        float w=cases[ci][0],h=cases[ci][1],r=cases[ci][2],shortest=fminf(w,h);
        float scale=shortest/44.0f,bezel=fminf(16.0f*scale,shortest*0.5f);
        float cap=LGButtonCandidateMaxDisplacement(w,h),cx=w*0.5f,cy=h*0.5f;
        unsigned inside=0,outside=0,lit=0,moved=0;
        for (unsigned y=0; y<(unsigned)h; ++y) for (unsigned x=0; x<(unsigned)w; ++x) {
            LGButtonOpticsResult q=LGButtonOpticsEvaluate((float)x+0.5f,(float)y+0.5f,w,h,cx,cy,r,bezel,108.0f,1.6f,2.0f,cap,scale,3.0f,true);
            assert(q.valid && isfinite(q.sampleU) && isfinite(q.sampleV));
            assert(isfinite(q.environmentU) && isfinite(q.environmentV) && isfinite(q.environmentWeight));
            assert(q.environmentWeight>=0.0f && q.environmentWeight<=0.28f);
            assert(q.sampleU>=0.5f/w && q.sampleU<=1.0f-0.5f/w);
            assert(q.sampleV>=0.5f/h && q.sampleV<=1.0f-0.5f/h);
            assert(q.environmentU>=0.5f/w && q.environmentU<=1.0f-0.5f/w);
            assert(q.environmentV>=0.5f/h && q.environmentV<=1.0f-0.5f/h);
            float dx=q.environmentU*w-((float)x+0.5f),dy=q.environmentV*h-((float)y+0.5f);
            assert(length2(dx,dy)<=cap*0.45f+0.001f);
            if(q.signedDistance<0.0f){inside++;if(q.environmentWeight>1e-5f)lit++;if(hypotf(dx,dy)>0.01f)moved++;}
            else {outside++;assert(q.environmentWeight==0.0f);assert(q.environmentU==q.sampleU&&q.environmentV==q.sampleV);}
        }
        assert(inside>0&&outside>0&&lit>0&&moved>0);
    }
    LGButtonOpticsResult boundary=LGButtonOpticsEvaluate(66.0f,87.99f,132,88,66,44,22,48,108,1.6f,2.0f,LGButtonCandidateMaxDisplacement(132,88),2.0f,3.0f,true);
    assert(boundary.valid&&boundary.signedDistance<0.0f&&boundary.environmentWeight<0.01f);
}

static void testEnvironmentRadianceContract(void) {
    const float w = 132.0f, h = 132.0f, cx = 66.0f, cy = 66.0f;
    const float cap = LGButtonCandidateMaxDisplacement(w, h);
    LGButtonOpticsResult mid = LGButtonOpticsEvaluate(
        99.5f, 66.5f, w, h, cx, cy, 66.0f, 48.0f, 108.0f, 1.6f,
        2.0f, cap, 3.0f, 1.5f, true);
    assert(mid.valid && mid.signedDistance < 0.0f);
    assert(isfinite(mid.environmentU) && isfinite(mid.environmentV));
    assert(isfinite(mid.environmentWeight) && mid.environmentWeight >= 0.0f &&
           mid.environmentWeight <= 0.28f);
    assert(mid.environmentU >= 0.5f / w && mid.environmentU <= 1.0f - 0.5f / w);
    assert(mid.environmentV >= 0.5f / h && mid.environmentV <= 1.0f - 0.5f / h);
    float envDx = mid.environmentU * w - 99.5f;
    float envDy = mid.environmentV * h - 66.5f;
    assert(length2(envDx, envDy) <= cap * 0.45f + 0.001f);

    LGButtonOpticsResult zero = LGButtonOpticsEvaluate(
        99.5f, 66.5f, w, h, cx, cy, 66.0f, 48.0f, 0.0f, 1.6f,
        2.0f, cap, 3.0f, 1.5f, true);
    LGButtonOpticsResult scaleZero = LGButtonOpticsEvaluate(
        99.5f, 66.5f, w, h, cx, cy, 66.0f, 48.0f, 108.0f, 1.6f,
        0.0f, cap, 3.0f, 1.5f, true);
    LGButtonOpticsResult iorOne = LGButtonOpticsEvaluate(
        99.5f, 66.5f, w, h, cx, cy, 66.0f, 48.0f, 108.0f, 1.0f,
        2.0f, cap, 3.0f, 1.5f, true);
    LGButtonOpticsResult off = LGButtonOpticsEvaluate(
        99.5f, 66.5f, w, h, cx, cy, 66.0f, 48.0f, 108.0f, 1.6f,
        2.0f, cap, 3.0f, 1.5f, false);
    LGButtonOpticsResult outside = LGButtonOpticsEvaluate(
        132.5f, 66.5f, w, h, cx, cy, 66.0f, 48.0f, 108.0f, 1.6f,
        2.0f, cap, 3.0f, 1.5f, true);
    const LGButtonOpticsResult *identity[] = {&zero, &scaleZero, &iorOne, &off, &outside};
    for (unsigned i = 0; i < sizeof(identity) / sizeof(identity[0]); ++i) {
        assert(identity[i]->environmentWeight == 0.0f);
        assert(fabsf(identity[i]->environmentU - identity[i]->sampleU) < 1e-6f);
        assert(fabsf(identity[i]->environmentV - identity[i]->sampleV) < 1e-6f);
    }

    /* Equal live-source radiance stays equal: no synthetic white/gray/black fill. */
    const float uniform[] = {0.0f, 0.216f, 1.0f};
    for (unsigned i = 0; i < 3; ++i) {
        float p = uniform[i];
        float out = LGBOEnvironmentMixPremultipliedChannel(p, 1.0f, p, 1.0f, 0.28f);
        assert(fabsf(out - p) < 1e-6f);
    }
    /* Straight-color normalization preserves alpha's premultiplied contract. */
    float halfAlpha = LGBOEnvironmentMixPremultipliedChannel(0.25f, 0.5f,
                                                               0.15f, 0.3f, 0.28f);
    assert(fabsf(halfAlpha - 0.25f) < 1e-6f);
    assert(LGBOEnvironmentMixPremultipliedChannel(0.0f, 0.0f, 0.8f, 1.0f, 0.28f) == 0.0f);
}

int main(void) {
    testEligibilityAndIsolation();
    testGeometryScales();
    testRoundAndCapsuleFields();
    testBoundaryContinuityAndIdentity();
    testFiniteUVAndFallback();
    testEnvironmentRasterContract();
    testEnvironmentRadianceContract();
    puts("button optics shared-source CPU contract: PASS");
    return 0;
}
