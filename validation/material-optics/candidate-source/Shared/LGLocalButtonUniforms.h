#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#if defined(__APPLE__)
#include <simd/simd.h>
#else
typedef struct __attribute__((aligned(8))) { float x,y; } simd_float2;
typedef struct __attribute__((aligned(16))) { float x,y,z,w; } simd_float4;
static inline simd_float2 simd_make_float2(float x,float y) { simd_float2 v={x,y}; return v; }
static inline simd_float4 simd_make_float4(float x,float y,float z,float w) { simd_float4 v={x,y,z,w}; return v; }
#endif
#include "LGButtonOpticalState.h"
#include "LGButtonPressureRoute.h"
#include "LGLocalButtonSourceContract.h"
#include "LGButtonMaterialCandidate.h"
#include "LGHostRegistry.h"

/* Original frozen 208-byte production Uniforms prefix + local-only contact tail. */
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
    simd_float2 buttonContactCenter; /* normalized target-local coordinates */
    float buttonContactPressure;
    float buttonContactEnabled; /* explicit local-source opt-in only */
    simd_float2 buttonSourceTargetOriginPixels; /* target ROI origin in source texture */
    float buttonSourceOverscanEnabled; /* direct sample path when zero/disabled */
} LGLocalButtonUniforms;
#if defined(__cplusplus)
static_assert(sizeof(LGLocalButtonUniforms)==240, "local renderer overscan Uniforms ABI drift");
static_assert(offsetof(LGLocalButtonUniforms,wallpaperOrigin)==72, "Uniforms offset drift");
static_assert(offsetof(LGLocalButtonUniforms,tintColor)==160, "Uniforms offset drift");
static_assert(offsetof(LGLocalButtonUniforms,buttonCandidateCenter)==184, "Uniforms offset drift");
static_assert(offsetof(LGLocalButtonUniforms,buttonCandidateRendererScale)==200, "Uniforms offset drift");
static_assert(offsetof(LGLocalButtonUniforms,buttonContactCenter)==208, "contact center offset drift");
static_assert(offsetof(LGLocalButtonUniforms,buttonContactPressure)==216, "contact pressure offset drift");
static_assert(offsetof(LGLocalButtonUniforms,buttonContactEnabled)==220, "contact gate offset drift");
static_assert(offsetof(LGLocalButtonUniforms,buttonSourceTargetOriginPixels)==224, "source ROI offset drift");
static_assert(offsetof(LGLocalButtonUniforms,buttonSourceOverscanEnabled)==232, "overscan gate offset drift");
#else
_Static_assert(sizeof(LGLocalButtonUniforms)==240, "local renderer overscan Uniforms ABI drift");
_Static_assert(offsetof(LGLocalButtonUniforms,wallpaperOrigin)==72, "Uniforms offset drift");
_Static_assert(offsetof(LGLocalButtonUniforms,tintColor)==160, "Uniforms offset drift");
_Static_assert(offsetof(LGLocalButtonUniforms,buttonCandidateCenter)==184, "Uniforms offset drift");
_Static_assert(offsetof(LGLocalButtonUniforms,buttonCandidateRendererScale)==200, "Uniforms offset drift");
_Static_assert(offsetof(LGLocalButtonUniforms,buttonContactCenter)==208, "contact center offset drift");
_Static_assert(offsetof(LGLocalButtonUniforms,buttonContactPressure)==216, "contact pressure offset drift");
_Static_assert(offsetof(LGLocalButtonUniforms,buttonContactEnabled)==220, "contact gate offset drift");
_Static_assert(offsetof(LGLocalButtonUniforms,buttonSourceTargetOriginPixels)==224, "source ROI offset drift");
_Static_assert(offsetof(LGLocalButtonUniforms,buttonSourceOverscanEnabled)==232, "overscan gate offset drift");
#endif

/* Promote the prior local 224-byte contact ABI into the new tail-extended
 * Metal buffer. The caller must provide exactly that frozen prefix; zeroing
 * the new fields selects the byte-identical no-overscan sampler path. */
static inline bool LGLocalButtonPromoteContactABI224(
    const void *legacyBytes, size_t legacyLength, LGLocalButtonUniforms *out) {
    if (!legacyBytes || !out || legacyLength!=224u) return false;
    memset(out,0,sizeof(*out));
    memcpy(out,legacyBytes,224u);
    return true;
}

typedef struct {
    unsigned bucket;
    float thickness, refractionScale;
} LGLocalButtonPressureUniform;
static inline bool LGLocalButtonPressureUniformFromState(
    const LGButtonOpticalState *state, float shortestSide, float baseThickness,
    float baseRefractionScale, LGLocalButtonPressureUniform *out) {
    if (!state || !out || !state->eligible || !isfinite(state->pressure) ||
        state->pressure<0.0f || state->pressure>1.0f ||
        !isfinite(baseRefractionScale) ||
        baseRefractionScale<0.0f || baseRefractionScale>3.0f) return false;
    unsigned bucket=LGOpticalPressureIndex(state,LG_BUTTON_PRESSURE_LEVELS);
    float thickness=0.0f, factor=1.0f;
    if (!LGButtonPressureMaterial(shortestSide,baseThickness,bucket,&thickness,&factor))
        return false;
    out->bucket=bucket;
    out->thickness=thickness;
    out->refractionScale=baseRefractionScale*factor;
    return isfinite(out->thickness) && isfinite(out->refractionScale);
}

/* Identical production host defaults + the existing shared scalar pressure
 * mapping. This is parameter assembly only, not a second optical formula.
 */
static inline bool LGLocalButtonBuildUniforms(
    const LGLocalButtonSourceContract *c, const LGButtonOpticalState *state,
    float drawableWidth, float drawableHeight, float rendererScale,
    bool explicitLocalOptIn, LGLocalButtonUniforms *out) {
    LGLocalButtonSourceLayout layout={0};
    if (!c || !state || !out || !state->eligible ||
        !LGLocalSourceLayoutForContract(c,c->textureWidth,c->textureHeight,&layout) ||
        state->geometryGeneration!=c->targetGeometryGeneration ||
        !isfinite(drawableWidth) || !isfinite(drawableHeight) ||
        fabsf(drawableWidth-(float)layout.targetPixelWidth)>2.0f ||
        fabsf(drawableHeight-(float)layout.targetPixelHeight)>2.0f) return false;
    LGButtonOpticsGeometry g={0};
    if (!LGButtonCandidateBuildGeometry((float)layout.targetPixelWidth,
         (float)layout.targetPixelHeight,drawableWidth,drawableHeight,rendererScale,&g))
        return false;
    const LGHostDefinition *host=&kLGHostRegistry[LGHostIdentifierPrefsButtonCandidate];
    const float shortest=fminf(g.sourceWidth,g.sourceHeight);
    LGLocalButtonPressureUniform pressure={0};
    if (!LGLocalButtonPressureUniformFromState(state,shortest,host->glassThickness,
                                               host->refractionScale,&pressure)) return false;
    LGLocalButtonUniforms u={0};
    u.resolution=simd_make_float2(g.sourceWidth,g.sourceHeight);
    u.outputResolution=simd_make_float2(drawableWidth,drawableHeight);
    u.screenResolution=u.resolution; u.wallpaperResolution=u.resolution;
    u.radius=g.cornerRadius;
    u.bezelWidth=fminf(host->bezelWidthPoints*c->pointScale,shortest*.5f);
    u.glassThickness=pressure.thickness;
    u.refractionScale=pressure.refractionScale;
    u.refractiveIndex=host->refractiveIndex;
    u.samplingTransformX=simd_make_float2(1,0);
    u.samplingTransformY=simd_make_float2(0,1);
    u.backdropZoom=1; u.shapeScale=1;
    u.tintColor=simd_make_float4(0,0,0,0);
    u.buttonCandidate=1;
    u.buttonCandidateMaxOffset=LGButtonCandidateMaxDisplacement(g.sourceWidth,g.sourceHeight);
    u.buttonCandidateCenter=simd_make_float2(g.centerX,g.centerY);
    u.buttonCandidatePointScale=c->pointScale;
    u.buttonCandidateCornerRadius=g.cornerRadius;
    u.buttonCandidateRendererScale=rendererScale;
    const bool contactPhase=state->phase==LGOpticalTrackingInside ||
        state->phase==LGOpticalTrackingOutside || state->phase==LGOpticalReleasing ||
        state->phase==LGOpticalCancelled;
    if (explicitLocalOptIn && state->touchValid && contactPhase &&
        state->pressure>0.0f && isfinite(state->touchX) && isfinite(state->touchY) &&
        state->touchX>=0.0f && state->touchX<=1.0f &&
        state->touchY>=0.0f && state->touchY<=1.0f) {
        u.buttonContactCenter=simd_make_float2(state->touchX,state->touchY);
        u.buttonContactPressure=fminf(1.0f,fmaxf(0.0f,state->pressure));
        u.buttonContactEnabled=1.0f;
    }
    u.buttonSourceTargetOriginPixels=simd_make_float2(
        (float)(layout.leftPaddingPoints*c->pointScale),
        (float)(layout.topPaddingPoints*c->pointScale));
    if (c->sourceOverscanEnabled &&
        (layout.leftPaddingPoints>0.0 || layout.topPaddingPoints>0.0 ||
         layout.rightPaddingPoints>0.0 || layout.bottomPaddingPoints>0.0))
        u.buttonSourceOverscanEnabled=1.0f;
    *out=u;return true;
}
