#import "LGMeshLens.h"
#import "LGHostRegistry.h"
#import "LGLiveBackdropView.h"
#import <dlfcn.h>
#import <math.h>
#import <stdlib.h>
#import <objc/message.h>
#import <objc/runtime.h>

typedef struct {
    CGFloat x;
    CGFloat y;
    CGFloat z;
} LGMeshPoint3;

typedef struct {
    CGPoint from;
    LGMeshPoint3 to;
} LGMeshVertex;

typedef struct {
    unsigned int indices[4];
    float w[4];
} LGMeshFace;

static CGFloat LGMeshClamp(CGFloat value, CGFloat lo, CGFloat hi) {
    if (value < lo) return lo;
    if (value > hi) return hi;
    return value;
}

static CGFloat LGMeshSmooth(CGFloat t) {
    t = LGMeshClamp(t, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

static CGFloat LGMeshPref(NSString *key, CGFloat fallback, CGFloat lo, CGFloat hi) {
    id value = LGGlassPreferenceValue(key);
    CGFloat number = [value respondsToSelector:@selector(doubleValue)]
        ? (CGFloat)[value doubleValue] : fallback;
    if (!isfinite(number)) number = fallback;
    return LGMeshClamp(number, lo, hi);
}

static BOOL LGMeshLensEnabled(void) {
    id value = LGGlassPreferenceValue(@"Liquidify.Mesh.Enabled");
    if (![value isKindOfClass:[NSNumber class]]) return YES;
    return [value boolValue];
}

static BOOL LGMeshHostAllowsLens(NSString *filterType) {
    if (!filterType.length) return YES;
    switch (LGHostIdentifierForFilterType(filterType.UTF8String)) {
        case LGHostIdentifierClock:
        case LGHostIdentifierCoverSheet:
        case LGHostIdentifierKeyboard:
        case LGHostIdentifierTabBar:
        case LGHostIdentifierTabBarSelection:
        case LGHostIdentifierAssistiveTouch:
            return NO;
        default:
            return YES;
    }
}

static CGFloat LGMeshRoundedDistance(CGPoint point, CGSize size, CGFloat radius) {
    CGFloat halfW = size.width * 0.5;
    CGFloat halfH = size.height * 0.5;
    CGFloat r = LGMeshClamp(radius, 0.0, MIN(halfW, halfH));
    CGFloat qx = fabs(point.x) - (halfW - r);
    CGFloat qy = fabs(point.y) - (halfH - r);
    CGFloat outside = hypot(fmax(qx, 0.0), fmax(qy, 0.0));
    CGFloat inside = fmin(fmax(qx, qy), 0.0);
    return outside + inside - r;
}

static CGPoint LGMeshOutwardNormal(CGPoint centerPoint, CGSize size, CGFloat radius) {
    const CGFloat step = 0.5;
    CGFloat dx = LGMeshRoundedDistance(CGPointMake(centerPoint.x + step, centerPoint.y), size, radius)
               - LGMeshRoundedDistance(CGPointMake(centerPoint.x - step, centerPoint.y), size, radius);
    CGFloat dy = LGMeshRoundedDistance(CGPointMake(centerPoint.x, centerPoint.y + step), size, radius)
               - LGMeshRoundedDistance(CGPointMake(centerPoint.x, centerPoint.y - step), size, radius);
    CGFloat length = hypot(dx, dy);
    if (length < 0.0001) return CGPointZero;
    return CGPointMake(dx / length, dy / length);
}

static CGFloat LGMeshRimWeight(CGFloat insideDistance, CGFloat edge, CGFloat outer) {
    if (insideDistance >= edge || insideDistance <= -outer) return 0.0;
    if (insideDistance >= 0.0) return 1.0 - LGMeshSmooth(insideDistance / MAX(edge, 0.001));
    if (outer <= 0.001) return 0.0;
    return 1.0 - LGMeshSmooth((-insideDistance) / outer);
}

static CGFloat LGMeshReach(CGSize size) {
    CGFloat strength = LGMeshPref(@"Liquidify.RefractionStrength", 20.0, 10.0, 100.0);
    CGFloat outer = LGMeshPref(@"Liquidify.OuterEdge", 2.0, 0.0, 8.0);
    CGFloat peak = (strength / 20.0) * 6.0;
    CGFloat reach = peak + outer;
    CGFloat shortest = MIN(size.width, size.height);
    return LGMeshClamp(reach, 0.0, MIN(16.0, shortest * 0.35));
}

static NSString *LGMeshDepthNormalization(void) {
    NSString * __unsafe_unretained *symbol =
        (NSString * __unsafe_unretained *)dlsym(RTLD_DEFAULT, "kCADepthNormalizationNone");
    return symbol ? *symbol : nil;
}

static id LGMeshMakeTransform(const LGMeshVertex *vertices, NSUInteger vertexCount,
                              const LGMeshFace *faces, NSUInteger faceCount) {
    Class meshClass = NSClassFromString(@"CAMeshTransform");
    if (!meshClass) return nil;

    SEL depthSel = NSSelectorFromString(
        @"meshTransformWithVertexCount:vertices:faceCount:faces:depthNormalization:");
    if ([meshClass respondsToSelector:depthSel]) {
        typedef id (*LGMeshDepthCtor)(id, SEL, NSUInteger, const LGMeshVertex *,
                                      NSUInteger, const LGMeshFace *, id);
        LGMeshDepthCtor ctor = (LGMeshDepthCtor)objc_msgSend;
        return ctor(meshClass, depthSel, vertexCount, vertices, faceCount, faces,
                    LGMeshDepthNormalization());
    }

    SEL stepSel = NSSelectorFromString(
        @"meshTransformWithVertexCount:vertices:faceCount:faces:subdivisionSteps:");
    if ([meshClass respondsToSelector:stepSel]) {
        typedef id (*LGMeshStepCtor)(id, SEL, NSUInteger, const LGMeshVertex *,
                                     NSUInteger, const LGMeshFace *, int);
        LGMeshStepCtor ctor = (LGMeshStepCtor)objc_msgSend;
        return ctor(meshClass, stepSel, vertexCount, vertices, faceCount, faces, 0);
    }
    return nil;
}

BOOL LGMeshLensShouldApply(NSString *filterType, CGRect bounds) {
    if (!LGMeshLensEnabled() || !LGMeshHostAllowsLens(filterType)) return NO;
    if (!NSClassFromString(@"CAMeshTransform")) return NO;
    return CGRectGetWidth(bounds) >= 8.0 && CGRectGetHeight(bounds) >= 8.0;
}

CGFloat LGMeshLensBlurRadius(void) {
    return LGMeshPref(@"Liquidify.BlurRadius", 2.0, 0.0, 10.0);
}

NSString *LGMeshLensSignature(CGRect bounds, CGFloat cornerRadius) {
    CGFloat strength = LGMeshPref(@"Liquidify.RefractionStrength", 20.0, 10.0, 100.0);
    CGFloat edge = LGMeshPref(@"Liquidify.EdgeDistance", 12.0, 1.0, 48.0);
    CGFloat outer = LGMeshPref(@"Liquidify.OuterEdge", 2.0, 0.0, 8.0);
    CGFloat resolution = LGMeshPref(@"Liquidify.CornerResolution", 12.0, 4.0, 14.0);
    return [NSString stringWithFormat:@"%ld %ld %ld %.2f %.2f %.2f %.2f",
            lround(CGRectGetWidth(bounds)), lround(CGRectGetHeight(bounds)),
            lround(cornerRadius), strength, edge, outer, resolution];
}

id LGMeshLensTransform(CGRect bounds, CGFloat cornerRadius) {
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    if (width < 8.0 || height < 8.0) return nil;

    CGFloat edge = LGMeshPref(@"Liquidify.EdgeDistance", 12.0, 1.0, 48.0);
    CGFloat outer = LGMeshPref(@"Liquidify.OuterEdge", 2.0, 0.0, 8.0);
    NSInteger resolution = (NSInteger)llround(LGMeshPref(@"Liquidify.CornerResolution", 12.0, 4.0, 14.0));
    NSInteger extraColumns = (NSInteger)ceil(width / MAX(edge, 4.0));
    NSInteger extraRows = (NSInteger)ceil(height / MAX(edge, 4.0));
    NSInteger columns = MIN(25, MAX(resolution, extraColumns) + 1);
    NSInteger rows = MIN(25, MAX(resolution, extraRows) + 1);
    NSUInteger vertexCount = (NSUInteger)(columns * rows);
    NSUInteger faceCount = (NSUInteger)((columns - 1) * (rows - 1));

    LGMeshVertex *vertices = calloc(vertexCount, sizeof(LGMeshVertex));
    LGMeshFace *faces = calloc(faceCount, sizeof(LGMeshFace));
    if (!vertices || !faces) {
        free(vertices);
        free(faces);
        return nil;
    }

    CGSize size = CGSizeMake(width, height);
    CGFloat reach = LGMeshReach(size);
    NSUInteger index = 0;
    for (NSInteger row = 0; row < rows; row++) {
        CGFloat v = rows == 1 ? 0.5 : (CGFloat)row / (CGFloat)(rows - 1);
        for (NSInteger column = 0; column < columns; column++) {
            CGFloat u = columns == 1 ? 0.5 : (CGFloat)column / (CGFloat)(columns - 1);
            CGPoint centerPoint = CGPointMake((u - 0.5) * width, (v - 0.5) * height);
            CGFloat inside = -LGMeshRoundedDistance(centerPoint, size, cornerRadius);
            CGFloat weight = LGMeshRimWeight(inside, edge, outer);
            CGPoint normal = weight > 0.001
                ? LGMeshOutwardNormal(centerPoint, size, cornerRadius) : CGPointZero;
            CGFloat shift = reach * weight;
            LGMeshVertex vertex;
            vertex.to = (LGMeshPoint3){ u, v, 0.0 };
            vertex.from = CGPointMake(LGMeshClamp(u + normal.x * shift / width, -0.35, 1.35),
                                      LGMeshClamp(v + normal.y * shift / height, -0.35, 1.35));
            vertices[index++] = vertex;
        }
    }

    NSUInteger faceIndex = 0;
    for (NSInteger row = 0; row < rows - 1; row++) {
        for (NSInteger column = 0; column < columns - 1; column++) {
            unsigned int tl = (unsigned int)(row * columns + column);
            LGMeshFace face = {
                .indices = {
                    tl,
                    tl + 1,
                    (unsigned int)((row + 1) * columns + column + 1),
                    (unsigned int)((row + 1) * columns + column)
                },
                .w = { 1.0f, 1.0f, 1.0f, 1.0f }
            };
            faces[faceIndex++] = face;
        }
    }

    id mesh = LGMeshMakeTransform(vertices, vertexCount, faces, faceCount);
    free(vertices);
    free(faces);
    return mesh;
}
