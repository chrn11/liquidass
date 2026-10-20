#pragma once

#include <stdint.h>
#if defined(__cplusplus)
#include <cmath>
using std::isfinite;
#else
#include <math.h>
#endif

typedef enum LGSurfaceRole {
    LGSurfaceRolePanel = 0, LGSurfaceRoleText, LGSurfaceRoleClock,
    LGSurfaceRoleButton, LGSurfaceRoleSlider, LGSurfaceRoleSwitch,
    LGSurfaceRoleKeyboard, LGSurfaceRoleTabSelection, LGSurfaceRoleCount
} LGSurfaceRole;

typedef enum LGSurfaceInteractionPhase {
    LGSurfaceInteractionIdle = 0, LGSurfaceInteractionDown,
    LGSurfaceInteractionDraggingInside, LGSurfaceInteractionDraggingOutside,
    LGSurfaceInteractionRelease, LGSurfaceInteractionCancel,
    LGSurfaceInteractionPhaseCount
} LGSurfaceInteractionPhase;

typedef enum LGSurfaceBackgroundProfile {
    LGSurfaceBackgroundProfileCurrent = 0, LGSurfaceBackgroundProfileHighFidelity,
    LGSurfaceBackgroundProfileBalanced, LGSurfaceBackgroundProfileNativeFallback,
    LGSurfaceBackgroundProfileCount
} LGSurfaceBackgroundProfile;

typedef enum LGSurfaceQualityTier {
    LGSurfaceQualityTierCurrent = 0, LGSurfaceQualityTierHigh,
    LGSurfaceQualityTierBalanced, LGSurfaceQualityTierProtected,
    LGSurfaceQualityTierCount
} LGSurfaceQualityTier;

typedef enum LGSurfaceShapeKind {
    LGSurfaceShapeRectangle = 0, LGSurfaceShapeRoundedRectangle,
    LGSurfaceShapeCircle, LGSurfaceShapeCapsule, LGSurfaceShapeGlyph,
    LGSurfaceShapeKindCount
} LGSurfaceShapeKind;

typedef enum LGSurfaceMaskSourceKind {
    LGSurfaceMaskSourceNone = 0, LGSurfaceMaskSourceLayerCornerRadius,
    LGSurfaceMaskSourceTextMask, LGSurfaceMaskSourceImageAlpha,
    LGSurfaceMaskSourceExplicitPath, LGSurfaceMaskSourceExplicitRectangle,
    LGSurfaceMaskSourceKindCount
} LGSurfaceMaskSourceKind;

typedef enum LGSurfaceGeometrySpace {
    LGSurfaceGeometryHostLocal = 0, LGSurfaceGeometryMaterialLocal,
    LGSurfaceGeometryWindow, LGSurfaceGeometrySpaceCount
} LGSurfaceGeometrySpace;

typedef enum LGSurfaceNestedMaterialPolicy {
    LGSurfaceNestedMaterialAllow = 0,
    LGSurfaceNestedMaterialShareCaptureOwner,
    LGSurfaceNestedMaterialNativeFallback,
    LGSurfaceNestedMaterialSkip,
    LGSurfaceNestedMaterialPolicyCount
} LGSurfaceNestedMaterialPolicy;

typedef uint32_t LGSurfaceDescriptorFlags;
enum {
    LGSurfaceDescriptorEnabled = 1u << 0,
    LGSurfaceDescriptorGeometryValid = 1u << 1,
    LGSurfaceDescriptorTouchValid = 1u << 2,
    LGSurfaceDescriptorForegroundOwned = 1u << 3,
    LGSurfaceDescriptorAccessibility = 1u << 4,
    LGSurfaceDescriptorNativeFallback = 1u << 5,
    LGSurfaceDescriptorKnownFlags = (1u << 6) - 1
};

#define LG_SURFACE_DESCRIPTOR_VERSION_1 1u
/* Fixed-width and pointer-free. ABI is shared with Backboardd. */
typedef struct LGSurfaceDescriptorV1 {
    uint32_t version, byteSize, flags, reserved;
    uint64_t hostGeneration, geometryGeneration, appearanceGeneration;
    uint64_t interactionGeneration, captureOwnerGeneration;
    uint32_t role, interactionPhase, backgroundProfile, qualityTier;
    uint32_t captureGroup, captureOwnerGroup, nestingDepth, nestedMaterialPolicy;
    uint32_t shapeKind, maskSource, geometrySpace, reservedV1;
    float boundsOriginX, boundsOriginY, boundsWidth, boundsHeight;
    float maskOriginX, maskOriginY, maskWidth, maskHeight;
    float cornerRadius, touchX, touchY, pressProgress;
} LGSurfaceDescriptorV1;

static inline LGSurfaceDescriptorV1 LGSurfaceDescriptorV1MakeDefault(
    LGSurfaceRole role, uint64_t generation) {
    LGSurfaceDescriptorV1 value = {0};
    value.version = LG_SURFACE_DESCRIPTOR_VERSION_1;
    value.byteSize = (uint32_t)sizeof(value);
    value.hostGeneration = generation;
    value.role = (uint32_t)role;
    value.interactionPhase = LGSurfaceInteractionIdle;
    value.backgroundProfile = LGSurfaceBackgroundProfileCurrent;
    value.qualityTier = LGSurfaceQualityTierCurrent;
    value.captureGroup = UINT32_MAX;
    value.captureOwnerGroup = UINT32_MAX;
    value.shapeKind = LGSurfaceShapeRectangle;
    value.maskSource = LGSurfaceMaskSourceNone;
    value.geometrySpace = LGSurfaceGeometryHostLocal;
    value.touchX = value.touchY = -1.0f;
    return value;
}

static inline uint64_t LGSurfaceGenerationNext(uint64_t generation) {
    return generation == UINT64_MAX ? UINT64_MAX : generation + 1;
}

static inline LGSurfaceNestedMaterialPolicy LGSurfaceNestedMaterialPolicyFromDepth(uint32_t depth) {
    return depth ? LGSurfaceNestedMaterialNativeFallback : LGSurfaceNestedMaterialAllow;
}

/* Mask and bounds use the SAME declared space. Empty, source-less metadata
 * may not carry GeometryValid; a usable mask must stay inside the owning bounds.
 * Double arithmetic avoids overflow from finite float endpoint sums. */
static inline int LGSurfaceGeometryValid(const LGSurfaceDescriptorV1 *value) {
    if (!value || !isfinite(value->boundsOriginX) || !isfinite(value->boundsOriginY) ||
        !isfinite(value->boundsWidth) || !isfinite(value->boundsHeight) ||
        !isfinite(value->maskOriginX) || !isfinite(value->maskOriginY) ||
        !isfinite(value->maskWidth) || !isfinite(value->maskHeight) ||
        !isfinite(value->cornerRadius) || !isfinite(value->pressProgress) ||
        value->boundsWidth < 0.0f || value->boundsHeight < 0.0f ||
        value->maskWidth < 0.0f || value->maskHeight < 0.0f ||
        value->cornerRadius < 0.0f || value->pressProgress < 0.0f ||
        value->pressProgress > 1.0f) return 0;
    if (!(value->flags & LGSurfaceDescriptorGeometryValid)) return 1;
    if (value->boundsWidth <= 0.0f || value->boundsHeight <= 0.0f ||
        value->maskWidth <= 0.0f || value->maskHeight <= 0.0f ||
        value->maskSource == LGSurfaceMaskSourceNone) return 0;
    return (double)value->maskOriginX >= (double)value->boundsOriginX &&
        (double)value->maskOriginY >= (double)value->boundsOriginY &&
        (double)value->maskOriginX + value->maskWidth <=
            (double)value->boundsOriginX + value->boundsWidth &&
        (double)value->maskOriginY + value->maskHeight <=
            (double)value->boundsOriginY + value->boundsHeight;
}

static inline int LGSurfaceGeometryEqual(const LGSurfaceDescriptorV1 *a,
                                        const LGSurfaceDescriptorV1 *b) {
    return a && b && a->shapeKind == b->shapeKind && a->maskSource == b->maskSource &&
        a->geometrySpace == b->geometrySpace &&
        a->boundsOriginX == b->boundsOriginX && a->boundsOriginY == b->boundsOriginY &&
        a->boundsWidth == b->boundsWidth && a->boundsHeight == b->boundsHeight &&
        a->maskOriginX == b->maskOriginX && a->maskOriginY == b->maskOriginY &&
        a->maskWidth == b->maskWidth && a->maskHeight == b->maskHeight &&
        a->cornerRadius == b->cornerRadius &&
        ((a->flags ^ b->flags) & LGSurfaceDescriptorGeometryValid) == 0;
}

static inline int LGSurfaceAppearanceEqual(const LGSurfaceDescriptorV1 *a,
                                          const LGSurfaceDescriptorV1 *b) {
    return a && b && a->role == b->role && a->backgroundProfile == b->backgroundProfile &&
        a->qualityTier == b->qualityTier;
}

static inline int LGSurfaceInteractionEqual(const LGSurfaceDescriptorV1 *a,
                                           const LGSurfaceDescriptorV1 *b) {
    if (!a || !b || a->interactionPhase != b->interactionPhase ||
        a->pressProgress != b->pressProgress ||
        ((a->flags ^ b->flags) & LGSurfaceDescriptorTouchValid)) return 0;
    return !(a->flags & LGSurfaceDescriptorTouchValid) ||
        (a->touchX == b->touchX && a->touchY == b->touchY);
}

static inline int LGSurfaceDescriptorV1IsValid(const LGSurfaceDescriptorV1 *value) {
    if (!value || value->version != LG_SURFACE_DESCRIPTOR_VERSION_1 ||
        value->byteSize != sizeof(*value) || value->reserved || value->reservedV1 ||
        (value->flags & ~LGSurfaceDescriptorKnownFlags) || value->role >= LGSurfaceRoleCount ||
        value->interactionPhase >= LGSurfaceInteractionPhaseCount ||
        value->backgroundProfile >= LGSurfaceBackgroundProfileCount ||
        value->qualityTier >= LGSurfaceQualityTierCount ||
        value->nestedMaterialPolicy >= LGSurfaceNestedMaterialPolicyCount ||
        value->shapeKind >= LGSurfaceShapeKindCount ||
        value->maskSource >= LGSurfaceMaskSourceKindCount ||
        value->geometrySpace >= LGSurfaceGeometrySpaceCount ||
        !LGSurfaceGeometryValid(value)) return 0;
    if ((value->flags & LGSurfaceDescriptorTouchValid) &&
        (!isfinite(value->touchX) || !isfinite(value->touchY) ||
         value->touchX < 0.0f || value->touchX > 1.0f ||
         value->touchY < 0.0f || value->touchY > 1.0f)) return 0;
    return 1;
}

static inline int LGSurfaceDescriptorCanBindHostGeneration(
    const LGSurfaceDescriptorV1 *current, int hasBinding,
    const LGSurfaceDescriptorV1 *next) {
    if (!current || !next || !next->hostGeneration ||
        !LGSurfaceDescriptorV1IsValid(next)) return 0;
    if (hasBinding && next->hostGeneration == current->hostGeneration &&
        (next->captureOwnerGeneration != current->captureOwnerGeneration ||
         next->captureGroup != current->captureGroup ||
         next->captureOwnerGroup != current->captureOwnerGroup)) return 0;
    if (!hasBinding) {
        if (!next->captureOwnerGeneration ||
            next->captureOwnerGeneration != next->hostGeneration) return 0;
        if (next->geometryGeneration != current->geometryGeneration ||
            next->appearanceGeneration != current->appearanceGeneration ||
            next->interactionGeneration != current->interactionGeneration) return 0;
    } else if (next->hostGeneration != current->hostGeneration) {
        if (!next->captureOwnerGeneration ||
            next->captureOwnerGeneration != next->hostGeneration ||
            next->captureOwnerGeneration <= current->hostGeneration) return 0;
    }
    if (next->geometryGeneration < current->geometryGeneration ||
        next->appearanceGeneration < current->appearanceGeneration ||
        next->interactionGeneration < current->interactionGeneration) return 0;
    if (hasBinding && next->geometryGeneration == current->geometryGeneration &&
        !LGSurfaceGeometryEqual(current, next)) return 0;
    if (hasBinding && next->appearanceGeneration == current->appearanceGeneration &&
        !LGSurfaceAppearanceEqual(current, next)) return 0;
    if (hasBinding && next->interactionGeneration == current->interactionGeneration &&
        !LGSurfaceInteractionEqual(current, next)) return 0;
    return 1;
}

#ifdef __cplusplus
static_assert(sizeof(LGSurfaceDescriptorV1) == 152, "surface descriptor ABI changed");
#else
_Static_assert(sizeof(LGSurfaceDescriptorV1) == 152, "surface descriptor ABI changed");
#endif

#ifdef __OBJC__
#define LG_SURFACE_BACKGROUND_PROFILE_KEY @"Surface.BackgroundProfile"
#define LG_SURFACE_QUALITY_TIER_KEY @"Surface.QualityTier"
static inline LGSurfaceBackgroundProfile LGSurfaceBackgroundProfileFromPreference(id value) {
    NSInteger n = [value respondsToSelector:@selector(integerValue)]
        ? [value integerValue] : LGSurfaceBackgroundProfileCurrent;
    if (n < 0 || n >= LGSurfaceBackgroundProfileCount)
        return LGSurfaceBackgroundProfileCurrent;
    return (LGSurfaceBackgroundProfile)n;
}
static inline LGSurfaceQualityTier LGSurfaceQualityTierFromPreference(id value) {
    NSInteger n = [value respondsToSelector:@selector(integerValue)]
        ? [value integerValue] : LGSurfaceQualityTierCurrent;
    if (n < 0 || n >= LGSurfaceQualityTierCount) return LGSurfaceQualityTierCurrent;
    return (LGSurfaceQualityTier)n;
}
static inline LGSurfaceQualityTier LGSurfaceQualityTierFromGlobalQualityPreference(id value) {
    double quality = [value respondsToSelector:@selector(doubleValue)]
        ? [value doubleValue] : 1.0;
    if (!isfinite(quality)) quality = 1.0;
    if (quality >= 0.72) return LGSurfaceQualityTierHigh;
    if (quality >= 0.35) return LGSurfaceQualityTierBalanced;
    return LGSurfaceQualityTierProtected;
}
#endif
