#include <assert.h>
#include <float.h>
#include <stdio.h>
#include "LGSurfaceDescriptor.h"

static LGSurfaceDescriptorV1 usable(void) {
    LGSurfaceDescriptorV1 d = LGSurfaceDescriptorV1MakeDefault(LGSurfaceRolePanel, 7);
    d.captureGroup = d.captureOwnerGroup = 3;
    d.captureOwnerGeneration = 7;
    d.flags = LGSurfaceDescriptorEnabled | LGSurfaceDescriptorGeometryValid;
    d.maskSource = LGSurfaceMaskSourceLayerCornerRadius;
    d.boundsOriginX = d.maskOriginX = 10;
    d.boundsOriginY = d.maskOriginY = -20;
    d.boundsWidth = d.maskWidth = 100;
    d.boundsHeight = d.maskHeight = 80;
    d.cornerRadius = 12;
    return d;
}
#define BAD(field, v) do { d = good; d.field = (v); assert(!LGSurfaceDescriptorV1IsValid(&d)); } while (0)

int main(void) {
    LGSurfaceDescriptorV1 good = usable(), d = good, next;
    assert(sizeof(d) == 152);
    assert(LGSurfaceDescriptorV1IsValid(&good));
    assert(!LGSurfaceDescriptorV1IsValid(NULL));
    BAD(version, 2); BAD(byteSize, 128); BAD(reserved, 1); BAD(reservedV1, 1);
    BAD(flags, 1u << 31); BAD(role, LGSurfaceRoleCount);
    BAD(shapeKind, LGSurfaceShapeKindCount); BAD(maskSource, LGSurfaceMaskSourceKindCount);
    BAD(geometrySpace, LGSurfaceGeometrySpaceCount);
    BAD(backgroundProfile, LGSurfaceBackgroundProfileCount); BAD(qualityTier, LGSurfaceQualityTierCount);
    BAD(interactionPhase, LGSurfaceInteractionPhaseCount); BAD(nestedMaterialPolicy, LGSurfaceNestedMaterialPolicyCount);
    BAD(boundsOriginX, NAN); BAD(boundsOriginY, INFINITY);
    BAD(boundsWidth, -1); BAD(boundsHeight, -1); BAD(boundsWidth, INFINITY);
    BAD(maskOriginX, NAN); BAD(maskOriginY, INFINITY); BAD(maskWidth, NAN);
    BAD(maskHeight, INFINITY); BAD(maskWidth, -1); BAD(maskHeight, -1);
    BAD(maskOriginX, 9); BAD(maskOriginY, -21); BAD(maskWidth, 101); BAD(maskHeight, 81);
    BAD(boundsWidth, 0); BAD(maskWidth, 0); BAD(maskSource, LGSurfaceMaskSourceNone);
    BAD(cornerRadius, NAN); BAD(cornerRadius, -1); BAD(pressProgress, NAN);
    BAD(pressProgress, -0.01f); BAD(pressProgress, 1.01f);
    d = good; d.flags |= LGSurfaceDescriptorTouchValid; d.touchX = 0; d.touchY = 1;
    assert(LGSurfaceDescriptorV1IsValid(&d));
    d.touchX = NAN; assert(!LGSurfaceDescriptorV1IsValid(&d));
    d.touchX = 1.01f; assert(!LGSurfaceDescriptorV1IsValid(&d));
    d.touchX = 0; d.touchY = -1; assert(!LGSurfaceDescriptorV1IsValid(&d));
    d.flags &= ~LGSurfaceDescriptorTouchValid; assert(LGSurfaceDescriptorV1IsValid(&d));
    d = LGSurfaceDescriptorV1MakeDefault(LGSurfaceRolePanel, 1);
    assert(LGSurfaceDescriptorV1IsValid(&d)); // no usable geometry promised
    // Finite float endpoints would overflow in float arithmetic; use double.
    d = good; d.boundsOriginX = FLT_MAX; d.boundsWidth = FLT_MAX;
    d.maskOriginX = FLT_MAX; d.maskWidth = FLT_MAX;
    assert(LGSurfaceDescriptorV1IsValid(&d));
    assert(LGSurfaceNestedMaterialPolicyFromDepth(0) == LGSurfaceNestedMaterialAllow);
    assert(LGSurfaceNestedMaterialPolicyFromDepth(1) == LGSurfaceNestedMaterialNativeFallback);
    assert(LGSurfaceGenerationNext(9) == 10);
    assert(LGSurfaceGenerationNext(UINT64_MAX) == UINT64_MAX);
    d = good; assert(LGSurfaceGeometryEqual(&d, &good));
    d.cornerRadius++; assert(!LGSurfaceGeometryEqual(&d, &good));
    d = good; d.maskOriginX++; assert(!LGSurfaceGeometryEqual(&d, &good));
    d = good; d.flags ^= LGSurfaceDescriptorNativeFallback;
    assert(LGSurfaceGeometryEqual(&d, &good)); // health is not geometry
    d = good; d.captureOwnerGeneration = 0;
    next = good; assert(LGSurfaceDescriptorCanBindHostGeneration(&d, 0, &next));
    next.geometryGeneration++; assert(!LGSurfaceDescriptorCanBindHostGeneration(&d, 0, &next));
    next = good; assert(LGSurfaceDescriptorCanBindHostGeneration(&good, 1, &next));
    next.cornerRadius++; assert(!LGSurfaceDescriptorCanBindHostGeneration(&good, 1, &next));
    next.geometryGeneration++; assert(LGSurfaceDescriptorCanBindHostGeneration(&good, 1, &next));
    next = good; next.backgroundProfile = LGSurfaceBackgroundProfileBalanced;
    assert(!LGSurfaceDescriptorCanBindHostGeneration(&good, 1, &next));
    next.appearanceGeneration++; assert(LGSurfaceDescriptorCanBindHostGeneration(&good, 1, &next));
    next = good; next.interactionPhase = LGSurfaceInteractionDown; next.pressProgress = 1;
    assert(!LGSurfaceDescriptorCanBindHostGeneration(&good, 1, &next));
    next.interactionGeneration++; assert(LGSurfaceDescriptorCanBindHostGeneration(&good, 1, &next));
    next = good; next.flags |= LGSurfaceDescriptorTouchValid; next.touchX = 0.5f; next.touchY = 0.5f;
    assert(!LGSurfaceDescriptorCanBindHostGeneration(&good, 1, &next));
    next.interactionGeneration++; assert(LGSurfaceDescriptorCanBindHostGeneration(&good, 1, &next));
    next = good; next.touchX = 0.2f; // invalid touch is ignored, not a touch event
    assert(LGSurfaceDescriptorCanBindHostGeneration(&good, 1, &next));
    next = good;
    next.geometryGeneration++; next.appearanceGeneration++; next.interactionGeneration++;
    assert(LGSurfaceDescriptorCanBindHostGeneration(&good, 1, &next));
    d = next; next.geometryGeneration--; assert(!LGSurfaceDescriptorCanBindHostGeneration(&d, 1, &next));
    next = d; next.appearanceGeneration--; assert(!LGSurfaceDescriptorCanBindHostGeneration(&d, 1, &next));
    next = d; next.interactionGeneration--; assert(!LGSurfaceDescriptorCanBindHostGeneration(&d, 1, &next));
    next = d; next.captureGroup++; assert(!LGSurfaceDescriptorCanBindHostGeneration(&d, 1, &next));
    next = d; next.captureOwnerGroup++; assert(!LGSurfaceDescriptorCanBindHostGeneration(&d, 1, &next));
    next = d; next.captureOwnerGeneration++; assert(!LGSurfaceDescriptorCanBindHostGeneration(&d, 1, &next));
    next = d; next.hostGeneration = next.captureOwnerGeneration = 8;
    assert(LGSurfaceDescriptorCanBindHostGeneration(&d, 1, &next));
    d = next; next.hostGeneration = next.captureOwnerGeneration = 7;
    assert(!LGSurfaceDescriptorCanBindHostGeneration(&d, 1, &next));
    next = d; next.hostGeneration = next.captureOwnerGeneration = 0;
    assert(!LGSurfaceDescriptorCanBindHostGeneration(&d, 1, &next));
    puts("PASS: descriptor ABI, finite/mask bounds, flags, touch, idempotence, owner and stale generations");
    return 0;
}
