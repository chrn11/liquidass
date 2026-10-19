#pragma once

#include <stdbool.h>
#include <math.h>
#include <stdint.h>

/* The finite 7/36 offset bound is the sole inherited numeric cap from the
 * separate native experiment, which itself did NOT pass the visual goal. The
 * candidate renderer uses its own shared rounded-box dome/refraction formula;
 * no Apple/Liquidify parity or experimental-app equivalence is claimed. */
#define LG_BUTTON_CANDIDATE_CAP_NUM 7.0f
#define LG_BUTTON_CANDIDATE_CAP_DEN 36.0f
#define LG_BUTTON_CANDIDATE_MAX_DIM 16384.0f
#define LG_BUTTON_CANDIDATE_VIEW_SIZE_POINTS 44.0f
#define LG_BUTTON_CANDIDATE_CORNER_RADIUS_RATIO 0.5f

#define LGBO_STRUCT_BEGIN(name) typedef struct name {
#define LGBO_FIELD(type, name) type name;
#define LGBO_STRUCT_END(name) } name;
#define LGBO_FUNCTION_BEGIN(ret, name, args) static inline ret name args {
#define LGBO_STMT(line) line
#define LGBO_FUNCTION_END }
#include "LGButtonOpticsFormula.inc"
#include "LGLocalSourceMapping.inc"
#include "LGLocalMinification.inc"
#undef LGBO_FUNCTION_END
#undef LGBO_STMT
#undef LGBO_FUNCTION_BEGIN
#undef LGBO_STRUCT_END
#undef LGBO_FIELD
#undef LGBO_STRUCT_BEGIN

typedef struct {
    float sourceWidth;
    float sourceHeight;
    float destinationWidth;
    float destinationHeight;
    float rendererScale;
    float pointScaleX;
    float pointScaleY;
    float centerX;
    float centerY;
    float cornerRadius;
} LGButtonOpticsGeometry;

typedef struct {
    bool active;
} LGButtonCandidateInstanceState;

static inline bool LGButtonCandidateIsEligible(bool prefIsNSNumber,
                                                bool prefIsTrue,
                                                bool targetProcessAllowed,
                                                bool exactTargetClass,
                                                bool exactStockBackTarget,
                                                bool activeAndAttached) {
    return prefIsNSNumber && prefIsTrue && targetProcessAllowed &&
           exactTargetClass && exactStockBackTarget && activeAndAttached;
}

static inline bool LGButtonCandidateUpdateInstanceState(
    LGButtonCandidateInstanceState *state, bool desired) {
    if (!state || state->active == desired) return false;
    state->active = desired;
    return true;
}

static inline bool LGButtonCandidateGeometryValid(float width, float height,
                                                   float scale,
                                                   float cornerRadius) {
    if (!isfinite(width) || !isfinite(height) || !isfinite(scale) ||
        !isfinite(cornerRadius)) return false;
    if (width < 1.0f || height < 1.0f ||
        width > LG_BUTTON_CANDIDATE_MAX_DIM ||
        height > LG_BUTTON_CANDIDATE_MAX_DIM ||
        scale < 0.5f || scale > 4.0f || cornerRadius < 0.0f) return false;
    float shortest = fminf(width, height);
    return cornerRadius <= shortest * 0.5f + 0.01f;
}

static inline bool LGButtonCandidateBuildGeometry(float sourceWidth,
                                                   float sourceHeight,
                                                   float destinationWidth,
                                                   float destinationHeight,
                                                   float rendererScale,
                                                   LGButtonOpticsGeometry *out) {
    if (!out || !isfinite(sourceWidth) || !isfinite(sourceHeight) ||
        !isfinite(destinationWidth) || !isfinite(destinationHeight) ||
        !isfinite(rendererScale)) return false;
    if (sourceWidth < 1.0f || sourceHeight < 1.0f ||
        destinationWidth < 1.0f || destinationHeight < 1.0f ||
        sourceWidth > LG_BUTTON_CANDIDATE_MAX_DIM ||
        sourceHeight > LG_BUTTON_CANDIDATE_MAX_DIM ||
        destinationWidth > LG_BUTTON_CANDIDATE_MAX_DIM ||
        destinationHeight > LG_BUTTON_CANDIDATE_MAX_DIM ||
        rendererScale < 0.5f || rendererScale > 4.0f ||
        fabsf(destinationWidth - sourceWidth) > 2.0f ||
        fabsf(destinationHeight - sourceHeight) > 2.0f) return false;

    const float pointScaleX = sourceWidth / LG_BUTTON_CANDIDATE_VIEW_SIZE_POINTS;
    const float pointScaleY = sourceHeight / LG_BUTTON_CANDIDATE_VIEW_SIZE_POINTS;
    if (pointScaleX < 0.5f || pointScaleX > 4.0f ||
        pointScaleY < 0.5f || pointScaleY > 4.0f ||
        fabsf(pointScaleX - pointScaleY) > 0.02f * fmaxf(pointScaleX, pointScaleY) +
            (1.0f / LG_BUTTON_CANDIDATE_VIEW_SIZE_POINTS)) return false;

    LGButtonOpticsGeometry geometry = {};
    geometry.sourceWidth = sourceWidth;
    geometry.sourceHeight = sourceHeight;
    geometry.destinationWidth = destinationWidth;
    geometry.destinationHeight = destinationHeight;
    geometry.rendererScale = rendererScale;
    geometry.pointScaleX = pointScaleX;
    geometry.pointScaleY = pointScaleY;
    geometry.centerX = sourceWidth * 0.5f;
    geometry.centerY = sourceHeight * 0.5f;
    geometry.cornerRadius = LG_BUTTON_CANDIDATE_VIEW_SIZE_POINTS *
        LG_BUTTON_CANDIDATE_CORNER_RADIUS_RATIO * fminf(pointScaleX, pointScaleY);
    if (!LGButtonCandidateGeometryValid(sourceWidth, sourceHeight,
                                        rendererScale, geometry.cornerRadius))
        return false;
    *out = geometry;
    return true;
}

static inline float LGButtonCandidateMaxDisplacement(float width,
                                                      float height) {
    if (!isfinite(width) || !isfinite(height) || width < 1.0f || height < 1.0f ||
        width > LG_BUTTON_CANDIDATE_MAX_DIM ||
        height > LG_BUTTON_CANDIDATE_MAX_DIM) return 0.0f;
    return fminf(width, height) *
           (LG_BUTTON_CANDIDATE_CAP_NUM / LG_BUTTON_CANDIDATE_CAP_DEN);
}

static inline bool LGButtonCandidateFormatsCompatible(bool requested,
                                                       uint32_t sourceFormat,
                                                       uint32_t destinationFormat) {
    if (!requested) return true;
    // A matching nonzero format is only a conservative compatibility gate;
    // it does not establish color-space or alpha-premultiplication semantics.
    return sourceFormat != 0 && destinationFormat != 0 &&
           sourceFormat == destinationFormat;
}
