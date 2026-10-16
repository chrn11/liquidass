#pragma once
/* Bounded same-process source contract. No object/pixel-buffer/screen pointer,
 * cross-process token, or guessed CA identity is represented here. */
#include <stdbool.h>
#include <stdint.h>
#include <math.h>
#if defined(__APPLE__)
#include <CoreGraphics/CoreGraphics.h>
#else
typedef struct { double x, y; } LGPoint;
typedef struct { double width, height; } LGSize;
typedef struct { LGPoint origin; LGSize size; } CGRect;
static inline CGRect CGRectMake(double x,double y,double w,double h) {
    CGRect r={{x,y},{w,h}}; return r;
}
#endif

#ifndef LG_LOCAL_BUTTON_RENDERER_COMPILED
#define LG_LOCAL_BUTTON_RENDERER_COMPILED 0
#endif
#define LG_LOCAL_BUTTON_VIEW_POINTS 44.0
#define LG_LOCAL_BUTTON_SOURCE_MAX_AGE_SECONDS 0.100
#define LG_LOCAL_BUTTON_FUTURE_SLOP_SECONDS 0.005
#define LG_LOCAL_BUTTON_MAX_TEXTURE_DIMENSION 16384u
/* A 16pt/edge optical neighborhood is a bounded source-domain budget, not
 * a shader displacement increase or an unbounded screen/window crop. */
#define LG_LOCAL_BUTTON_MAX_OVERSCAN_PADDING_POINTS 16.0

typedef enum {
    LGLocalSourceNone=0,
    LGLocalSourceLiveAppOwnedTexture=1,
    LGLocalSourceStaticAsset=2,
    LGLocalSourceDeclaredSyntheticColor=3
} LGLocalSourceKind;
typedef enum {
    LGLocalAlphaOpaque=1,
    LGLocalAlphaPremultiplied=2,
    LGLocalAlphaStraight=3
} LGLocalAlphaMode;
typedef enum {
    LGLocalMaskRounded44=1,
    LGLocalMaskGlyph=2,
    LGLocalMaskUnknown=3
} LGLocalMaskKind;
typedef enum {
    LGLocalSourceValid=0, LGLocalSourceBadContract, LGLocalSourceBadOwner,
    LGLocalSourceBadGeneration, LGLocalSourceStale, LGLocalSourceBadGeometry,
    LGLocalSourceBadAlpha, LGLocalSourceBadFormat, LGLocalSourceHasForeground,
    LGLocalSourceApproximationNotAllowed
} LGLocalSourceValidation;

typedef struct {
    /* Both rects use the shared parent coordinate space of target/material siblings. */
    CGRect sourceRectInOwnerPoints; /* bounded source domain containing target; <=16pt/edge */
    CGRect targetRectInOwnerPoints; /* exact 44x44 owner-space material ROI */
    uint32_t textureWidth, textureHeight, pixelFormat;
    float pointScale;
    uint64_t ownerInstanceToken;    /* process-local, non-secret, never IPC identity */
    uint64_t ownerGeneration;       /* provider invalidates on owner replacement */
    uint64_t frameGeneration;       /* monotonic within ownerGeneration */
    uint64_t targetGeometryGeneration; /* must equal LGButtonOpticalState generation */
    double frameTimestampMonotonic; /* CACurrentMediaTime domain */
    LGLocalSourceKind sourceKind;
    LGLocalAlphaMode alphaMode;
    LGLocalMaskKind maskKind;
    bool backgroundOnly;
    bool targetForegroundExcluded;
    // A provider must lease immutable pixels while any frame/command retains
    // this contract. Same MTLTexture object does NOT otherwise freeze contents.
    bool immutableUntilFrameReleased;
    // The existing full shader works on linear, premultiplied sampled RGB.
    // _sRGB format alone does not establish alpha-premultiplication semantics.
    bool sampledRGBIsLinear;
    bool sampledRGBIsPremultiplied;
    /* Explicit provider opt-in. Zero-pad opt-in remains pixel-identical to the
     * legacy 44pt contract; when false, any enlarged source is rejected. */
    bool sourceOverscanEnabled;
} LGLocalButtonSourceContract;

typedef struct {
    double leftPaddingPoints, topPaddingPoints;
    double rightPaddingPoints, bottomPaddingPoints;
    uint32_t targetPixelWidth, targetPixelHeight;
} LGLocalButtonSourceLayout;

/* Validate the bounded source domain and derive the exact target ROI in pixels.
 * Owner coordinates use UIKit's downward-positive Y; the target is NOT rescaled
 * to the larger capture. */
static inline bool LGLocalFiniteRect(CGRect r);
static inline bool LGLocalSourceLayoutForContract(
    const LGLocalButtonSourceContract *c, uint32_t actualWidth,
    uint32_t actualHeight, LGLocalButtonSourceLayout *out) {
    if (!c || !out || !LGLocalFiniteRect(c->sourceRectInOwnerPoints) ||
        !LGLocalFiniteRect(c->targetRectInOwnerPoints) ||
        !isfinite(c->pointScale) || c->pointScale<0.5f || c->pointScale>4.0f ||
        !actualWidth || !actualHeight ||
        actualWidth>LG_LOCAL_BUTTON_MAX_TEXTURE_DIMENSION ||
        actualHeight>LG_LOCAL_BUTTON_MAX_TEXTURE_DIMENSION ||
        fabs(c->targetRectInOwnerPoints.size.width-LG_LOCAL_BUTTON_VIEW_POINTS)>0.01 ||
        fabs(c->targetRectInOwnerPoints.size.height-LG_LOCAL_BUTTON_VIEW_POINTS)>0.01 ||
        actualWidth!=c->textureWidth || actualHeight!=c->textureHeight ||
        !isfinite(c->sourceRectInOwnerPoints.origin.x+c->sourceRectInOwnerPoints.size.width) ||
        !isfinite(c->sourceRectInOwnerPoints.origin.y+c->sourceRectInOwnerPoints.size.height) ||
        !isfinite(c->targetRectInOwnerPoints.origin.x+c->targetRectInOwnerPoints.size.width) ||
        !isfinite(c->targetRectInOwnerPoints.origin.y+c->targetRectInOwnerPoints.size.height))
        return false;
    const CGRect s=c->sourceRectInOwnerPoints, t=c->targetRectInOwnerPoints;
    LGLocalButtonSourceLayout layout={0};
    layout.leftPaddingPoints=t.origin.x-s.origin.x;
    layout.topPaddingPoints=t.origin.y-s.origin.y;
    layout.rightPaddingPoints=(s.origin.x+s.size.width)-(t.origin.x+t.size.width);
    layout.bottomPaddingPoints=(s.origin.y+s.size.height)-(t.origin.y+t.size.height);
    const double pads[]={layout.leftPaddingPoints,layout.topPaddingPoints,
                         layout.rightPaddingPoints,layout.bottomPaddingPoints};
    bool anyPadding=false;
    for (unsigned i=0;i<4;i++) {
        if (!isfinite(pads[i]) || pads[i]<0.0 ||
            pads[i]>LG_LOCAL_BUTTON_MAX_OVERSCAN_PADDING_POINTS) return false;
        if (!c->sourceOverscanEnabled && pads[i]!=0.0) return false;
        anyPadding=anyPadding || pads[i]!=0.0;
    }
    if (s.size.width>LG_LOCAL_BUTTON_VIEW_POINTS+2.0*LG_LOCAL_BUTTON_MAX_OVERSCAN_PADDING_POINTS+0.01 ||
        s.size.height>LG_LOCAL_BUTTON_VIEW_POINTS+2.0*LG_LOCAL_BUTTON_MAX_OVERSCAN_PADDING_POINTS+0.01 ||
        fabs((double)actualWidth-s.size.width*c->pointScale)>1.0 ||
        fabs((double)actualHeight-s.size.height*c->pointScale)>1.0) return false;
    if (!anyPadding) {
        // Preserve every accepted old zero-pad pixel grid, including +/-1px
        // capture rounding. Never silently resample 133px into a new132px view.
        if (fabs((double)actualWidth/actualHeight-1.0)>0.02) return false;
        layout.targetPixelWidth=actualWidth;layout.targetPixelHeight=actualHeight;
        *out=layout;return true;
    }
    // New enlarged providers must state an exact source-pixel extent. Unlike
    // legacy zero-pad, no ambiguous +/-1px capture rounding is inferred here.
    if (fabs((double)actualWidth-s.size.width*c->pointScale)>0.001 ||
        fabs((double)actualHeight-s.size.height*c->pointScale)>0.001) return false;
    double targetW=LG_LOCAL_BUTTON_VIEW_POINTS*c->pointScale;
    double targetH=LG_LOCAL_BUTTON_VIEW_POINTS*c->pointScale;
    if (!isfinite(targetW) || !isfinite(targetH) || targetW<1.0 || targetH<1.0 ||
        targetW>LG_LOCAL_BUTTON_MAX_TEXTURE_DIMENSION ||
        targetH>LG_LOCAL_BUTTON_MAX_TEXTURE_DIMENSION ||
        fabs(targetW-floor(targetW+0.5))>0.001 ||
        fabs(targetH-floor(targetH+0.5))>0.001) return false;
    layout.targetPixelWidth=(uint32_t)floor(targetW+0.5);
    layout.targetPixelHeight=(uint32_t)floor(targetH+0.5);
    // Rounding the full capture must never push a supposedly contained target
    // ROI outside the actual texture. The shader's clamp is not a repair for
    // a provider that supplied missing/incorrect source pixels.
    if (layout.leftPaddingPoints*c->pointScale+layout.targetPixelWidth >
            (double)actualWidth+0.001 ||
        layout.topPaddingPoints*c->pointScale+layout.targetPixelHeight >
            (double)actualHeight+0.001) return false;
    *out=layout;
    return true;
}

static inline bool LGLocalSourceTargetPixelSize(
    const LGLocalButtonSourceContract *c, uint32_t *width, uint32_t *height) {
    LGLocalButtonSourceLayout layout={0};
    if (!c || !width || !height ||
        !LGLocalSourceLayoutForContract(c,c->textureWidth,c->textureHeight,&layout)) return false;
    *width=layout.targetPixelWidth; *height=layout.targetPixelHeight;
    return true;
}

static inline bool LGLocalFiniteRect(CGRect r) {
    return isfinite(r.origin.x) && isfinite(r.origin.y) &&
           isfinite(r.size.width) && isfinite(r.size.height) &&
           r.size.width > 0.0 && r.size.height > 0.0;
}
static inline bool LGLocalSourceIsApproximate(LGLocalSourceKind kind) {
    return kind==LGLocalSourceStaticAsset || kind==LGLocalSourceDeclaredSyntheticColor;
}
static inline bool LGLocalRectSame(CGRect a, CGRect b) {
    const double e=0.01;
    return fabs(a.origin.x-b.origin.x)<=e && fabs(a.origin.y-b.origin.y)<=e &&
           fabs(a.size.width-b.size.width)<=e && fabs(a.size.height-b.size.height)<=e;
}
static inline LGLocalSourceValidation LGLocalValidateSourceContract(
    const LGLocalButtonSourceContract *c, double now, uint64_t expectedOwner,
    uint64_t expectedOwnerGeneration, uint64_t minimumFrameGeneration,
    uint64_t targetGeometryGeneration, uint32_t actualWidth,
    uint32_t actualHeight, uint32_t actualFormat, uint32_t drawableFormat,
    bool ownerAlive, bool allowApproximate) {
    if (!c || !isfinite(now) || now<0 || !c->ownerInstanceToken ||
        !c->ownerGeneration || !c->frameGeneration || !c->targetGeometryGeneration ||
        !isfinite(c->pointScale) || c->pointScale<0.5f || c->pointScale>4.0f ||
        !isfinite(c->frameTimestampMonotonic) || c->frameTimestampMonotonic<0 ||
        c->textureWidth==0 || c->textureHeight==0 ||
        c->textureWidth>LG_LOCAL_BUTTON_MAX_TEXTURE_DIMENSION ||
        c->textureHeight>LG_LOCAL_BUTTON_MAX_TEXTURE_DIMENSION ||
        c->sourceKind<LGLocalSourceLiveAppOwnedTexture ||
        c->sourceKind>LGLocalSourceDeclaredSyntheticColor ||
        c->maskKind!=LGLocalMaskRounded44 ||
        !c->immutableUntilFrameReleased) return LGLocalSourceBadContract;
    if (!ownerAlive || c->ownerInstanceToken!=expectedOwner)
        return LGLocalSourceBadOwner;
    if (c->ownerGeneration!=expectedOwnerGeneration ||
        c->frameGeneration<minimumFrameGeneration ||
        c->targetGeometryGeneration!=targetGeometryGeneration)
        return LGLocalSourceBadGeneration;
    double age=now-c->frameTimestampMonotonic;
    if (age < -LG_LOCAL_BUTTON_FUTURE_SLOP_SECONDS ||
        age > LG_LOCAL_BUTTON_SOURCE_MAX_AGE_SECONDS) return LGLocalSourceStale;
    LGLocalButtonSourceLayout layout={0};
    if (!LGLocalSourceLayoutForContract(c,actualWidth,actualHeight,&layout) ||
        actualFormat!=c->pixelFormat || actualWidth==0 || actualHeight==0)
        return LGLocalSourceBadGeometry;
    if ((c->alphaMode!=LGLocalAlphaOpaque && c->alphaMode!=LGLocalAlphaPremultiplied) ||
        !c->sampledRGBIsLinear || !c->sampledRGBIsPremultiplied)
        return LGLocalSourceBadAlpha;
    // First supported exact sample domain, matching build14/15 evidence.
    // Do not silently expand to HDR/P3/straight-alpha/other texture formats.
    if (c->pixelFormat!=81u || c->pixelFormat!=drawableFormat)
        return LGLocalSourceBadFormat;
    if (!c->backgroundOnly || !c->targetForegroundExcluded)
        return LGLocalSourceHasForeground;
    if (LGLocalSourceIsApproximate(c->sourceKind) && !allowApproximate)
        return LGLocalSourceApproximationNotAllowed;
    return LGLocalSourceValid;
}

static inline bool LGLocalButtonMayRender(bool compiledIn, bool explicitOptIn,
    bool stateEligible, bool targetAttached, bool sourceValid, bool pipelineReady) {
    return compiledIn && explicitOptIn && stateEligible && targetAttached &&
           sourceValid && pipelineReady;
}

/* Ordered value metadata per instance. Call only AFTER the other contract and
 * actual texture checks pass. Same frame generation must preserve its original
 * timestamp; otherwise a stale frame could be relabelled fresh indefinitely.
 */
typedef struct {
    uint64_t ownerToken, ownerGeneration, frameGeneration;
    double frameTimestamp;
} LGLocalSourceCursor;
static inline bool LGLocalSourceAcceptOrder(LGLocalSourceCursor *cursor,
                                             const LGLocalButtonSourceContract *c) {
    if (!cursor || !c || !c->ownerInstanceToken || !c->ownerGeneration ||
        !c->frameGeneration || !isfinite(c->frameTimestampMonotonic)) return false;
    if (cursor->ownerToken) {
        if (c->ownerInstanceToken!=cursor->ownerToken ||
            c->ownerGeneration<cursor->ownerGeneration) return false;
        if (c->ownerGeneration==cursor->ownerGeneration) {
            if (c->frameGeneration<cursor->frameGeneration) return false;
            if (c->frameGeneration==cursor->frameGeneration &&
                c->frameTimestampMonotonic!=cursor->frameTimestamp) return false;
            if (c->frameGeneration>cursor->frameGeneration &&
                c->frameTimestampMonotonic<cursor->frameTimestamp) return false;
        }
    }
    cursor->ownerToken=c->ownerInstanceToken;
    cursor->ownerGeneration=c->ownerGeneration;
    cursor->frameGeneration=c->frameGeneration;
    cursor->frameTimestamp=c->frameTimestampMonotonic;
    return true;
}
static inline double LGLocalSourceExpiryDelay(
    const LGLocalButtonSourceContract *c, double now) {
    if (!c || !isfinite(now) || !isfinite(c->frameTimestampMonotonic)) return 0;
    return fmax(0, c->frameTimestampMonotonic +
                       LG_LOCAL_BUTTON_SOURCE_MAX_AGE_SECONDS - now);
}

static inline bool LGLocalSameFrameDescriptor(
    const LGLocalButtonSourceContract *a, const LGLocalButtonSourceContract *b) {
    if (!a || !b) return false;
    // Field equality, not memcmp: CGRect/enum/bool struct padding is not data.
    return a->ownerInstanceToken==b->ownerInstanceToken &&
        a->ownerGeneration==b->ownerGeneration && a->frameGeneration==b->frameGeneration &&
        a->targetGeometryGeneration==b->targetGeometryGeneration &&
        a->frameTimestampMonotonic==b->frameTimestampMonotonic &&
        a->textureWidth==b->textureWidth && a->textureHeight==b->textureHeight &&
        a->pixelFormat==b->pixelFormat && a->pointScale==b->pointScale &&
        a->sourceKind==b->sourceKind && a->alphaMode==b->alphaMode && a->maskKind==b->maskKind &&
        a->backgroundOnly==b->backgroundOnly && a->targetForegroundExcluded==b->targetForegroundExcluded &&
        a->immutableUntilFrameReleased==b->immutableUntilFrameReleased &&
        a->sampledRGBIsLinear==b->sampledRGBIsLinear &&
        a->sampledRGBIsPremultiplied==b->sampledRGBIsPremultiplied &&
        a->sourceOverscanEnabled==b->sourceOverscanEnabled &&
        a->sourceRectInOwnerPoints.origin.x==b->sourceRectInOwnerPoints.origin.x &&
        a->sourceRectInOwnerPoints.origin.y==b->sourceRectInOwnerPoints.origin.y &&
        a->sourceRectInOwnerPoints.size.width==b->sourceRectInOwnerPoints.size.width &&
        a->sourceRectInOwnerPoints.size.height==b->sourceRectInOwnerPoints.size.height &&
        a->targetRectInOwnerPoints.origin.x==b->targetRectInOwnerPoints.origin.x &&
        a->targetRectInOwnerPoints.origin.y==b->targetRectInOwnerPoints.origin.y &&
        a->targetRectInOwnerPoints.size.width==b->targetRectInOwnerPoints.size.width &&
        a->targetRectInOwnerPoints.size.height==b->targetRectInOwnerPoints.size.height;
}

/* Last accepted immutable descriptor survives view clear/expiry. Ordering is
 * checked independently first; this binds repeated frame generations to the
 * very same texture object, without retaining its GPU lease after invalidation.
 * Caller compares an ARC weak MTLTexture reference, not raw pointer integers.
 */
static inline bool LGLocalRepeatedFrameIdentityValid(
    const LGLocalButtonSourceContract *candidate,
    const LGLocalButtonSourceContract *lastAccepted, bool hasLastAccepted,
    bool exactSameLiveTextureObject) {
    if (!candidate || !candidate->ownerInstanceToken ||
        !candidate->ownerGeneration || !candidate->frameGeneration) return false;
    if (!hasLastAccepted) return true;
    if (!lastAccepted) return false;
    const bool repeated = candidate->ownerInstanceToken==lastAccepted->ownerInstanceToken &&
        candidate->ownerGeneration==lastAccepted->ownerGeneration &&
        candidate->frameGeneration==lastAccepted->frameGeneration;
    return !repeated || (exactSameLiveTextureObject &&
                         LGLocalSameFrameDescriptor(candidate,lastAccepted));
}
