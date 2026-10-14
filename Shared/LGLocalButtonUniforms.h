#pragma once
#include <stddef.h>
#include <stdint.h>
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

/* Exact 208-byte field order of the frozen production Uniforms / full MSL. */
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
} LGLocalButtonUniforms;
#if defined(__cplusplus)
static_assert(sizeof(LGLocalButtonUniforms)==208, "local renderer Uniforms ABI drift");
static_assert(offsetof(LGLocalButtonUniforms,wallpaperOrigin)==72, "Uniforms offset drift");
static_assert(offsetof(LGLocalButtonUniforms,tintColor)==160, "Uniforms offset drift");
static_assert(offsetof(LGLocalButtonUniforms,buttonCandidateCenter)==184, "Uniforms offset drift");
static_assert(offsetof(LGLocalButtonUniforms,buttonCandidateRendererScale)==200, "Uniforms offset drift");
#else
_Static_assert(sizeof(LGLocalButtonUniforms)==208, "local renderer Uniforms ABI drift");
_Static_assert(offsetof(LGLocalButtonUniforms,wallpaperOrigin)==72, "Uniforms offset drift");
_Static_assert(offsetof(LGLocalButtonUniforms,tintColor)==160, "Uniforms offset drift");
_Static_assert(offsetof(LGLocalButtonUniforms,buttonCandidateCenter)==184, "Uniforms offset drift");
_Static_assert(offsetof(LGLocalButtonUniforms,buttonCandidateRendererScale)==200, "Uniforms offset drift");
#endif

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
    LGLocalButtonUniforms *out) {
    if (!c || !state || !out || !state->eligible ||
        !isfinite(c->pointScale) || c->pointScale<0.5f || c->pointScale>4.0f ||
        fabs((double)c->textureWidth-44.0*c->pointScale)>1.0 ||
        fabs((double)c->textureHeight-44.0*c->pointScale)>1.0 ||
        state->geometryGeneration!=c->targetGeometryGeneration) return false;
    LGButtonOpticsGeometry g={0};
    if (!LGButtonCandidateBuildGeometry((float)c->textureWidth,
         (float)c->textureHeight,drawableWidth,drawableHeight,rendererScale,&g))
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
    *out=u;return true;
}
