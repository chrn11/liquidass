#import "LGAppOwnedButtonSourceProvider.h"
#import "LGAppOwnedLeasePolicy.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#include <atomic>
#include <math.h>
#include <stdlib.h>
#include <string.h>

static const CFTimeInterval kLGAppOwnedMinimumCaptureInterval = 1.0/15.0;
static const CFTimeInterval kLGAppOwnedMaximumCacheAge = 0.066;
static const CGFloat kLGAppOwnedGeometryEpsilon = 0.001;
static std::atomic<uint64_t> gLGAppOwnedNextOwnerToken{1};

static uint64_t LGAppOwnedAllocateOwnerToken(void) {
    uint64_t token=gLGAppOwnedNextOwnerToken.load(std::memory_order_relaxed);
    while (token!=0 && token!=UINT64_MAX) {
        if (gLGAppOwnedNextOwnerToken.compare_exchange_weak(token,token+1,
                std::memory_order_relaxed,std::memory_order_relaxed)) return token;
    }
    return 0; // Saturate permanently; never wrap and reuse an earlier token.
}

static BOOL LGAppOwnedRectFinite(CGRect r) {
    return isfinite(CGRectGetMinX(r)) && isfinite(CGRectGetMinY(r)) &&
           isfinite(CGRectGetWidth(r)) && isfinite(CGRectGetHeight(r)) &&
           CGRectGetWidth(r)>0 && CGRectGetHeight(r)>0;
}

static BOOL LGAppOwnedRectEqualExactly(CGRect a, CGRect b) {
    return CGRectGetMinX(a)==CGRectGetMinX(b) && CGRectGetMinY(a)==CGRectGetMinY(b) &&
           CGRectGetWidth(a)==CGRectGetWidth(b) && CGRectGetHeight(a)==CGRectGetHeight(b);
}

static BOOL LGAppOwnedRectContainsRect(CGRect outer, CGRect inner) {
    return LGAppOwnedRectFinite(outer) && LGAppOwnedRectFinite(inner) &&
        CGRectGetMinX(inner)>=CGRectGetMinX(outer)-kLGAppOwnedGeometryEpsilon &&
        CGRectGetMinY(inner)>=CGRectGetMinY(outer)-kLGAppOwnedGeometryEpsilon &&
        CGRectGetMaxX(inner)<=CGRectGetMaxX(outer)+kLGAppOwnedGeometryEpsilon &&
        CGRectGetMaxY(inner)<=CGRectGetMaxY(outer)+kLGAppOwnedGeometryEpsilon;
}

static BOOL LGAppOwnedAxisAlignedAffine(CGAffineTransform t) {
    const CGFloat e=1.0e-6;
    return isfinite(t.a)&&isfinite(t.b)&&isfinite(t.c)&&isfinite(t.d)&&
           isfinite(t.tx)&&isfinite(t.ty)&&t.a>0&&t.d>0&&fabs(t.b)<=e&&fabs(t.c)<=e;
}

static BOOL LGAppOwnedAxisAlignedLayerTransform(CATransform3D t) {
    const CGFloat e=1.0e-6;
    return CATransform3DIsAffine(t) &&
        isfinite(t.m11)&&isfinite(t.m12)&&isfinite(t.m21)&&isfinite(t.m22)&&
        isfinite(t.m41)&&isfinite(t.m42)&&
        t.m11>0&&t.m22>0&&fabs(t.m12)<=e&&fabs(t.m21)<=e&&
        fabs(t.m13)<=e&&fabs(t.m14)<=e&&fabs(t.m23)<=e&&fabs(t.m24)<=e&&
        fabs(t.m31)<=e&&fabs(t.m32)<=e&&fabs(t.m34)<=e&&fabs(t.m43)<=e&&
        fabs(t.m33-1.0)<=e&&fabs(t.m44-1.0)<=e;
}

static BOOL LGAppOwnedContainsView(UIView *outer, UIView *inner) {
    if (!outer || !inner) return NO;
    for (UIView *v=inner; v; v=v.superview) if (v==outer) return YES;
    return NO;
}

static UIView *LGAppOwnedCommonAncestor(UIView *a, UIView *b) {
    if (!a || !b) return nil;
    for (UIView *x=a; x; x=x.superview)
        for (UIView *y=b; y; y=y.superview) if (x==y) return x;
    return nil;
}

static BOOL LGAppOwnedAxisAlignedViewPath(UIView *view, UIView *stopInclusive) {
    if (!view) return NO;
    UIView *v=view;
    while (v) {
        if (!LGAppOwnedAxisAlignedAffine(v.transform) ||
            !LGAppOwnedAxisAlignedLayerTransform(v.layer.transform) ||
            !LGAppOwnedAxisAlignedLayerTransform(v.layer.sublayerTransform)) return NO;
        if (stopInclusive && v==stopInclusive) return YES;
        v=v.superview;
    }
    return stopInclusive==nil;
}

static BOOL LGAppOwnedKnownUnsupportedLayer(CALayer *layer) {
    NSString *name=NSStringFromClass(layer.class).lowercaseString;
    NSArray<NSString *> *denied=@[@"metal",@"eagl",@"player",@"samplebuffer",
        @"video",@"remote",@"hosted",@"backdrop",@"visualeffect",
        @"replicator",@"emitter",@"tiled",@"transformlayer"];
    for (NSString *part in denied) if ([name containsString:part]) return YES;
    NSArray<NSString *> *classNames=@[@"CAMetalLayer",@"CAEAGLLayer",
        @"AVPlayerLayer",@"AVSampleBufferDisplayLayer",@"CAEmitterLayer",
        @"CAReplicatorLayer",@"CATiledLayer",@"CATransformLayer"];
    for (NSString *className in classNames) {
        Class cls=NSClassFromString(className);
        if (cls && [layer isKindOfClass:cls]) return YES;
    }
    return NO;
}

static BOOL LGAppOwnedLayerHasUnsupportedFilter(CALayer *layer) {
    NSArray<NSString *> *keys=@[@"filters",@"backgroundFilters",@"compositingFilter"];
    for (NSString *key in keys) {
        SEL getter=NSSelectorFromString(key);
        if (![layer respondsToSelector:getter]) continue;
        @try {
            id value=[layer valueForKey:key];
            if ([value isKindOfClass:NSArray.class]) {
                if ([(NSArray *)value count]) return YES;
            } else if (value) return YES;
        } @catch (NSException *exception) { (void)exception; return YES; }
    }
    return NO;
}

static BOOL LGAppOwnedLayerTreeCPUReadable(CALayer *root, NSUInteger *budget) {
    if (!root || !budget || *budget==0 || LGAppOwnedKnownUnsupportedLayer(root) ||
        !LGAppOwnedAxisAlignedLayerTransform(root.transform) ||
        !LGAppOwnedAxisAlignedLayerTransform(root.sublayerTransform) ||
        root.mask || LGAppOwnedLayerHasUnsupportedFilter(root) || root.animationKeys.count) return NO;
    (*budget)--;
    id contents=root.contents;
    if (contents && CFGetTypeID((__bridge CFTypeRef)contents)!=CGImageGetTypeID()) return NO;
    NSArray<CALayer *> *children=root.sublayers;
    for (CALayer *child in children)
        if (!LGAppOwnedLayerTreeCPUReadable(child,budget)) return NO;
    return YES;
}

static BOOL LGAppOwnedViewTreeCPUReadable(UIView *root, NSUInteger *budget) {
    if (!root || !budget || *budget==0) return NO;
    NSString *name=NSStringFromClass(root.class).lowercaseString;
    NSArray<NSString *> *denied=@[@"mtkview",@"wkwebview",@"webview",@"player",
        @"video",@"samplebuffer",@"remote",@"hosted",@"visualeffect",@"backdrop"];
    for (NSString *part in denied) if ([name containsString:part]) return NO;
    NSArray<NSString *> *classNames=@[@"MTKView",@"WKWebView",@"UIWebView",
        @"UIVisualEffectView",@"AVPlayerViewController"];
    for (NSString *className in classNames) {
        Class cls=NSClassFromString(className);
        if (cls && [root isKindOfClass:cls]) return NO;
    }
    (*budget)--;
    for (UIView *child in root.subviews)
        if (!LGAppOwnedViewTreeCPUReadable(child,budget)) return NO;
    return YES;
}

static BOOL LGAppOwnedSameWindowScene(UIView *a, UIView *b) {
    if (!a || !b || !a.window || a.window!=b.window) return NO;
    if (@available(iOS 13.0,*)) return a.window.windowScene==b.window.windowScene;
    return YES;
}

@interface LGAppOwnedTextureSlot : NSObject {
@public
    LGAppOwnedLeaseSlotValue leasePolicy;
}
@property(nonatomic,strong) id<MTLTexture> texture;
@property(nonatomic,assign) LGLocalButtonSourceContract contract;
@property(nonatomic,assign) CGRect rootBounds;
@property(nonatomic,assign) CGRect rootBoundsInParent;
@property(nonatomic,assign) CGRect sourceRectInRoot;
@property(nonatomic,assign) uint64_t dirtyGeneration;
@end
@implementation LGAppOwnedTextureSlot
@end

@interface LGAppOwnedButtonSourceProvider () {
    __weak UIView *_sourceRoot;
    __weak UIView *_targetView;
    __weak UIView *_materialView;
    id<MTLDevice> _device;
    UIEdgeInsets _edgePadding;
    BOOL _explicitOptIn;
    uint64_t _ownerToken;
    uint64_t _ownerGeneration;
    uint64_t _targetGeometryGeneration;
    uint64_t _frameGeneration;
    uint64_t _dirtyGeneration;
    BOOL _invalidated;
    BOOL _hasCaptureAttempt;
    CFTimeInterval _lastCaptureAttempt;
    BOOL _cacheValid;
    NSUInteger _cachedSlotIndex;
    uint64_t _cachedSlotEpoch;
    CFTimeInterval _cachedAt;
    CGRect _cachedTargetRect;
    BOOL _hasCachedTargetRect;
    uint64_t _lastSuccessfulTargetGeometryGeneration;
    NSLock *_leaseLock;
    NSLock *_stateLock;
    NSArray<LGAppOwnedTextureSlot *> *_slots;
    LGAppOwnedButtonSourceStatus _lastStatus;
}
- (void)endLeaseForSlot:(NSUInteger)slotIndex ownerGeneration:(uint64_t)ownerGeneration epoch:(uint64_t)epoch;
@end

@implementation LGAppOwnedButtonSourceProvider

- (instancetype)initWithSourceRoot:(UIView *)sourceRoot targetView:(UIView *)targetView
                             device:(id<MTLDevice>)device edgePadding:(UIEdgeInsets)edgePadding
                      explicitOptIn:(BOOL)explicitOptIn {
    if (!NSThread.isMainThread || !sourceRoot || !targetView || !device ||
        sourceRoot==targetView || LGAppOwnedContainsView(sourceRoot,targetView) ||
        LGAppOwnedContainsView(targetView,sourceRoot) || !explicitOptIn ||
        !isfinite(edgePadding.top)||!isfinite(edgePadding.left)||
        !isfinite(edgePadding.bottom)||!isfinite(edgePadding.right) ||
        edgePadding.top<0||edgePadding.left<0||edgePadding.bottom<0||edgePadding.right<0 ||
        edgePadding.top>LG_LOCAL_BUTTON_MAX_OVERSCAN_PADDING_POINTS ||
        edgePadding.left>LG_LOCAL_BUTTON_MAX_OVERSCAN_PADDING_POINTS ||
        edgePadding.bottom>LG_LOCAL_BUTTON_MAX_OVERSCAN_PADDING_POINTS ||
        edgePadding.right>LG_LOCAL_BUTTON_MAX_OVERSCAN_PADDING_POINTS) return nil;
    uint64_t token=LGAppOwnedAllocateOwnerToken();
    if (!token) return nil;
    if ((self=[super init])) {
        _sourceRoot=sourceRoot; _targetView=targetView; _device=device;
        _edgePadding=edgePadding; _explicitOptIn=explicitOptIn;
        _ownerToken=token; _ownerGeneration=1; _dirtyGeneration=1;
        _leaseLock=[NSLock new]; _stateLock=[NSLock new];
        NSMutableArray<LGAppOwnedTextureSlot *> *slots=[NSMutableArray arrayWithCapacity:
            LG_APP_OWNED_TEXTURE_SLOT_COUNT];
        for (NSUInteger i=0;i<LG_APP_OWNED_TEXTURE_SLOT_COUNT;i++)
            [slots addObject:[LGAppOwnedTextureSlot new]];
        _slots=[slots copy]; _lastStatus=LGAppOwnedButtonSourceStatusReady;
    }
    return self;
}

- (LGAppOwnedButtonSourceStatus)lastStatus { return _lastStatus; }
- (uint64_t)ownerInstanceToken { return _ownerToken; }
- (uint64_t)ownerGeneration {
    [_stateLock lock]; uint64_t value=_ownerGeneration; [_stateLock unlock]; return value;
}

- (BOOL)bindMaterialViewForFeedbackExclusion:(UIView *)materialView
                                      device:(id<MTLDevice>)device {
    if (!NSThread.isMainThread) { _lastStatus=LGAppOwnedButtonSourceStatusMainThreadRequired; return NO; }
    UIView *root=_sourceRoot, *target=_targetView;
    if (!materialView || !device || !root || !target ||
        ![materialView isKindOfClass:MTKView.class] || ((MTKView *)materialView).device!=device) {
        _lastStatus=LGAppOwnedButtonSourceStatusInvalidConfiguration; return NO;
    }
    /* The host binds the actual renderer device after constructing it. No slot
     * exists yet, so pin the exact object used by LGLocalButtonMaterialView. */
    if (_frameGeneration!=0 && device!=_device) {
        _lastStatus=LGAppOwnedButtonSourceStatusInvalidConfiguration; return NO;
    }
    _device=device;
    if (materialView==target || root==materialView ||
        LGAppOwnedContainsView(root,target) || LGAppOwnedContainsView(target,root) ||
        LGAppOwnedContainsView(root,materialView) || LGAppOwnedContainsView(materialView,root) ||
        LGAppOwnedContainsView(target,materialView) || LGAppOwnedContainsView(materialView,target)) {
        _lastStatus=LGAppOwnedButtonSourceStatusFeedbackHierarchy; return NO;
    }
    if (target.superview!=materialView.superview || !LGAppOwnedSameWindowScene(root,target) ||
        !LGAppOwnedSameWindowScene(materialView,target)) {
        _lastStatus=LGAppOwnedButtonSourceStatusSceneOrWindowMismatch; return NO;
    }
    _materialView=materialView; _cacheValid=NO;
    _lastStatus=LGAppOwnedButtonSourceStatusReady;
    return YES;
}

- (BOOL)updateTargetGeometryGeneration:(uint64_t)generation {
    if (!NSThread.isMainThread) { _lastStatus=LGAppOwnedButtonSourceStatusMainThreadRequired; return NO; }
    if (!generation || generation<_targetGeometryGeneration) {
        _lastStatus=LGAppOwnedButtonSourceStatusInvalidConfiguration; return NO;
    }
    if (generation!=_targetGeometryGeneration) {
        _targetGeometryGeneration=generation; _cacheValid=NO;
    }
    _lastStatus=LGAppOwnedButtonSourceStatusReady; return YES;
}

- (BOOL)advanceOwnerGeneration {
    if (!NSThread.isMainThread) { _lastStatus=LGAppOwnedButtonSourceStatusMainThreadRequired; return NO; }
    [_stateLock lock];
    if (_ownerGeneration==UINT64_MAX || _dirtyGeneration==UINT64_MAX) {
        _invalidated=YES; [_stateLock unlock];
        _lastStatus=LGAppOwnedButtonSourceStatusOwnerUnavailable; return NO;
    }
    _ownerGeneration++; _dirtyGeneration++;
    [_stateLock unlock];
    _cacheValid=NO; _lastStatus=LGAppOwnedButtonSourceStatusReady; return YES;
}

- (void)markSourceContentDirty {
    if (!NSThread.isMainThread) return;
    if (_dirtyGeneration==UINT64_MAX) {
        [_stateLock lock]; _invalidated=YES; [_stateLock unlock];
        _cacheValid=NO; _lastStatus=LGAppOwnedButtonSourceStatusOwnerUnavailable; return;
    }
    _dirtyGeneration++; _cacheValid=NO; _lastStatus=LGAppOwnedButtonSourceStatusReady;
}

- (BOOL)isOwnerInstanceAlive:(uint64_t)ownerToken generation:(uint64_t)generation {
    [_stateLock lock];
    BOOL live=!_invalidated && ownerToken==_ownerToken && generation==_ownerGeneration;
    [_stateLock unlock];
    return live && _sourceRoot!=nil && _targetView!=nil && _materialView!=nil;
}

- (LGAppOwnedButtonSourceStatus)validateTarget:(UIView *)target
                          sourceRoot:(UIView *)root material:(UIView *)material
                              parent:(UIView **)outParent
                         targetRect:(CGRect *)outTargetRect
                         sourceRect:(CGRect *)outSourceRect
                       rootBoundsInParent:(CGRect *)outRootBoundsInParent
                     sourceRectInRoot:(CGRect *)outSourceRectInRoot {
    if (!root || !target || !material) return LGAppOwnedButtonSourceStatusOwnerUnavailable;
    if (target!=_targetView) return LGAppOwnedButtonSourceStatusWrongTarget;
    if (material!=_materialView) return LGAppOwnedButtonSourceStatusRendererNotBound;
    if (![material isKindOfClass:MTKView.class] || ((MTKView *)material).device!=_device ||
        target.superview!=material.superview)
        return LGAppOwnedButtonSourceStatusFeedbackHierarchy;
    if (root==target || root==material ||
        LGAppOwnedContainsView(root,target) || LGAppOwnedContainsView(target,root) ||
        LGAppOwnedContainsView(root,material) || LGAppOwnedContainsView(material,root) ||
        LGAppOwnedContainsView(target,material) || LGAppOwnedContainsView(material,target))
        return LGAppOwnedButtonSourceStatusFeedbackHierarchy;
    if (!LGAppOwnedSameWindowScene(root,target) || !LGAppOwnedSameWindowScene(material,target))
        return LGAppOwnedButtonSourceStatusSceneOrWindowMismatch;
    UIView *parent=target.superview;
    UIView *common=LGAppOwnedCommonAncestor(root,target);
    UIView *materialCommon=LGAppOwnedCommonAncestor(material,target);
    if (!parent || !common || materialCommon!=parent ||
        !LGAppOwnedAxisAlignedViewPath(root,nil) ||
        !LGAppOwnedAxisAlignedViewPath(target,nil) ||
        !LGAppOwnedAxisAlignedViewPath(material,nil))
        return LGAppOwnedButtonSourceStatusUnsupportedTransform;
    if (fabs(CGRectGetWidth(target.bounds)-LG_LOCAL_BUTTON_VIEW_POINTS)>0.01 ||
        fabs(CGRectGetHeight(target.bounds)-LG_LOCAL_BUTTON_VIEW_POINTS)>0.01 ||
        fabs(CGRectGetWidth(material.bounds)-LG_LOCAL_BUTTON_VIEW_POINTS)>0.01 ||
        fabs(CGRectGetHeight(material.bounds)-LG_LOCAL_BUTTON_VIEW_POINTS)>0.01)
        return LGAppOwnedButtonSourceStatusSourceDomainUnavailable;

    CGRect targetRect=[target convertRect:target.bounds toView:parent];
    CGRect materialRect=[material convertRect:material.bounds toView:parent];
    if (!LGAppOwnedRectFinite(targetRect) || !LGLocalRectSame(targetRect,materialRect) ||
        fabs(CGRectGetWidth(targetRect)-LG_LOCAL_BUTTON_VIEW_POINTS)>0.01 ||
        fabs(CGRectGetHeight(targetRect)-LG_LOCAL_BUTTON_VIEW_POINTS)>0.01)
        return LGAppOwnedButtonSourceStatusUnsupportedTransform;
    CGRect sourceRect=CGRectMake(CGRectGetMinX(targetRect)-_edgePadding.left,
        CGRectGetMinY(targetRect)-_edgePadding.top,
        CGRectGetWidth(targetRect)+_edgePadding.left+_edgePadding.right,
        CGRectGetHeight(targetRect)+_edgePadding.top+_edgePadding.bottom);
    CGRect rootBounds=root.bounds;
    CGRect rootBoundsInParent=[root convertRect:rootBounds toView:parent];
    CGRect sourceRectInRoot=[parent convertRect:sourceRect toView:root];
    if (!LGAppOwnedRectFinite(rootBoundsInParent) || !LGAppOwnedRectFinite(sourceRectInRoot) ||
        !LGAppOwnedRectContainsRect(rootBounds,sourceRectInRoot) ||
        CGRectGetWidth(sourceRect)>LG_LOCAL_BUTTON_VIEW_POINTS+
            2.0*LG_LOCAL_BUTTON_MAX_OVERSCAN_PADDING_POINTS+0.01 ||
        CGRectGetHeight(sourceRect)>LG_LOCAL_BUTTON_VIEW_POINTS+
            2.0*LG_LOCAL_BUTTON_MAX_OVERSCAN_PADDING_POINTS+0.01)
        return LGAppOwnedButtonSourceStatusSourceDomainUnavailable;

    /* Ancestor clipping/opacity is not reconstructed from the window. Refuse
     * domains that the source subtree would not actually present as-is. */
    for (UIView *v=root; v; v=v.superview) {
        if (v.hidden || v.alpha<0.999 || v.layer.mask)
            return LGAppOwnedButtonSourceStatusUnsupportedLayerContent;
        if (v!=root && (v.clipsToBounds || v.layer.masksToBounds)) {
            CGRect roi=[parent convertRect:sourceRect toView:v];
            if (!LGAppOwnedRectContainsRect(v.bounds,roi))
                return LGAppOwnedButtonSourceStatusSourceDomainUnavailable;
        }
        if (v==root.window) break;
    }
    if (outParent) *outParent=parent;
    if (outTargetRect) *outTargetRect=targetRect;
    if (outSourceRect) *outSourceRect=sourceRect;
    if (outRootBoundsInParent) *outRootBoundsInParent=rootBoundsInParent;
    if (outSourceRectInRoot) *outSourceRectInRoot=sourceRectInRoot;
    return LGAppOwnedButtonSourceStatusReady;
}

- (LGLocalButtonTextureFrame *)frameForSlot:(NSUInteger)index
                              ownerGeneration:(uint64_t)ownerGeneration
                                         epoch:(uint64_t)epoch
                                      contract:(LGLocalButtonSourceContract)contract
                                       texture:(id<MTLTexture>)texture {
    __weak LGAppOwnedButtonSourceProvider *weakSelf=self;
    dispatch_block_t ended=^{
        LGAppOwnedButtonSourceProvider *strongSelf=weakSelf;
        [strongSelf endLeaseForSlot:index ownerGeneration:ownerGeneration epoch:epoch];
    };
    LGLocalButtonTextureFrame *frame=[[LGLocalButtonTextureFrame alloc]
        initWithTexture:texture contract:contract leaseEnded:ended];
    if (!frame) [self endLeaseForSlot:index ownerGeneration:ownerGeneration epoch:epoch];
    return frame;
}

- (void)endLeaseForSlot:(NSUInteger)slotIndex ownerGeneration:(uint64_t)ownerGeneration
                  epoch:(uint64_t)epoch {
    [_leaseLock lock];
    if (slotIndex<_slots.count) {
        LGAppOwnedTextureSlot *slot=_slots[slotIndex];
        (void)LGAppOwnedLeaseEnd(&slot->leasePolicy,ownerGeneration,epoch);
    }
    [_leaseLock unlock];
}

- (BOOL)acquireCacheAtTime:(CFTimeInterval)now
                     index:(NSUInteger *)outIndex
                     epoch:(uint64_t *)outEpoch
                 contract:(LGLocalButtonSourceContract *)outContract
                   texture:(id<MTLTexture> __strong *)outTexture {
    if (!_cacheValid || !_slots.count || _cachedSlotIndex>=_slots.count ||
        now<_cachedAt || now-_cachedAt>=kLGAppOwnedMaximumCacheAge) return NO;
    [_leaseLock lock];
    LGAppOwnedTextureSlot *slot=_slots[_cachedSlotIndex];
    uint64_t owner=slot.contract.ownerGeneration;
    BOOL acquired=slot->leasePolicy.epoch==_cachedSlotEpoch &&
        owner==_ownerGeneration && LGAppOwnedLeaseAcquire(&slot->leasePolicy,owner,_cachedSlotEpoch);
    if (acquired) {
        if (outIndex) *outIndex=_cachedSlotIndex;
        if (outEpoch) *outEpoch=_cachedSlotEpoch;
        if (outContract) *outContract=slot.contract;
        if (outTexture) *outTexture=slot.texture;
    }
    [_leaseLock unlock];
    return acquired;
}

- (LGAppOwnedTextureSlot *)reserveWritableSlot:(NSUInteger *)outIndex epoch:(uint64_t *)outEpoch
                                ownerGeneration:(uint64_t)ownerGeneration {
    [_leaseLock lock];
    LGAppOwnedTextureSlot *chosen=nil;
    for (NSUInteger i=0;i<_slots.count;i++) {
        LGAppOwnedTextureSlot *slot=_slots[i];
        uint64_t epoch=0;
        if (LGAppOwnedLeaseCanReserve(&slot->leasePolicy) &&
            LGAppOwnedLeaseReserve(&slot->leasePolicy,ownerGeneration,&epoch)) {
            chosen=slot; if (outIndex) *outIndex=i; if (outEpoch) *outEpoch=epoch; break;
        }
    }
    [_leaseLock unlock];
    return chosen;
}

- (void)abortWritableSlot:(LGAppOwnedTextureSlot *)slot ownerGeneration:(uint64_t)ownerGeneration
                     epoch:(uint64_t)epoch {
    [_leaseLock lock];
    if (slot) (void)LGAppOwnedLeaseAbortWrite(&slot->leasePolicy,ownerGeneration,epoch);
    [_leaseLock unlock];
}

- (LGLocalButtonTextureFrame *)currentBackgroundFrameForTargetView:(UIView *)target
                                               monotonicTimestamp:(CFTimeInterval)now {
    if (!NSThread.isMainThread) { _lastStatus=LGAppOwnedButtonSourceStatusMainThreadRequired; return nil; }
    if (!LG_LOCAL_BUTTON_RENDERER_COMPILED || !_explicitOptIn) {
        _lastStatus=LGAppOwnedButtonSourceStatusDisabledByBuildGate; return nil;
    }
    if (!isfinite(now) || now<0) { _lastStatus=LGAppOwnedButtonSourceStatusInvalidConfiguration; return nil; }
    UIView *root=_sourceRoot, *configuredTarget=_targetView, *material=_materialView;
    if (!root || !configuredTarget || !material ||
        ![self isOwnerInstanceAlive:_ownerToken generation:self.ownerGeneration]) {
        _lastStatus=LGAppOwnedButtonSourceStatusOwnerUnavailable; return nil;
    }
    if (!target || target!=configuredTarget) { _lastStatus=LGAppOwnedButtonSourceStatusWrongTarget; return nil; }
    if (!_targetGeometryGeneration) { _lastStatus=LGAppOwnedButtonSourceStatusTargetGenerationMissing; return nil; }

    UIView *parent=nil; CGRect targetRect=CGRectZero, sourceRect=CGRectZero;
    CGRect rootBoundsInParent=CGRectZero, sourceRectInRoot=CGRectZero;
    LGAppOwnedButtonSourceStatus validation=[self validateTarget:target sourceRoot:root
        material:material parent:&parent targetRect:&targetRect sourceRect:&sourceRect
        rootBoundsInParent:&rootBoundsInParent sourceRectInRoot:&sourceRectInRoot];
    if (validation!=LGAppOwnedButtonSourceStatusReady) { _lastStatus=validation; return nil; }
    if (_hasCachedTargetRect && !LGLocalRectSame(_cachedTargetRect,targetRect) &&
        _targetGeometryGeneration<=_lastSuccessfulTargetGeometryGeneration) {
        _cacheValid=NO; _lastStatus=LGAppOwnedButtonSourceStatusTargetGenerationRequired; return nil;
    }
    NSUInteger viewBudget=512, layerBudget=512;
    if (!LGAppOwnedViewTreeCPUReadable(root,&viewBudget) ||
        !LGAppOwnedLayerTreeCPUReadable(root.layer,&layerBudget)) {
        _cacheValid=NO; _lastStatus=LGAppOwnedButtonSourceStatusUnsupportedLayerContent; return nil;
    }
    CGFloat pointScale=target.window.screen.scale;
    if (!isfinite(pointScale) || pointScale<0.5 || pointScale>4) {
        _lastStatus=LGAppOwnedButtonSourceStatusSourceDomainUnavailable; return nil;
    }
    double rawWidth=CGRectGetWidth(sourceRect)*(double)pointScale;
    double rawHeight=CGRectGetHeight(sourceRect)*(double)pointScale;
    if (!isfinite(rawWidth)||!isfinite(rawHeight)||rawWidth<1||rawHeight<1 ||
        fabs(rawWidth-floor(rawWidth+0.5))>0.001 ||
        fabs(rawHeight-floor(rawHeight+0.5))>0.001) {
        _lastStatus=LGAppOwnedButtonSourceStatusSourceDomainUnavailable; return nil;
    }
    uint32_t pixelWidth=(uint32_t)floor(rawWidth+0.5);
    uint32_t pixelHeight=(uint32_t)floor(rawHeight+0.5);
    if (!pixelWidth||!pixelHeight||pixelWidth>304u||pixelHeight>304u ||
        fabs(44.0*(double)pointScale-floor(44.0*(double)pointScale+0.5))>0.001) {
        _lastStatus=LGAppOwnedButtonSourceStatusSourceDomainUnavailable; return nil;
    }

    const uint64_t ownerGeneration=self.ownerGeneration;
    [_leaseLock lock];
    LGAppOwnedTextureSlot *cacheSlot=_cacheValid&&_cachedSlotIndex<_slots.count ? _slots[_cachedSlotIndex] : nil;
    BOOL cacheKeyMatches=cacheSlot && cacheSlot->leasePolicy.epoch==_cachedSlotEpoch &&
        cacheSlot.contract.ownerInstanceToken==_ownerToken &&
        cacheSlot.contract.ownerGeneration==ownerGeneration &&
        cacheSlot.contract.targetGeometryGeneration==_targetGeometryGeneration &&
        cacheSlot.dirtyGeneration==_dirtyGeneration &&
        LGAppOwnedRectEqualExactly(cacheSlot.rootBounds,root.bounds) &&
        LGAppOwnedRectEqualExactly(cacheSlot.rootBoundsInParent,rootBoundsInParent) &&
        LGAppOwnedRectEqualExactly(cacheSlot.sourceRectInRoot,sourceRectInRoot) &&
        LGAppOwnedRectEqualExactly(cacheSlot.contract.sourceRectInOwnerPoints,sourceRect) &&
        LGAppOwnedRectEqualExactly(cacheSlot.contract.targetRectInOwnerPoints,targetRect) &&
        fabs(cacheSlot.contract.pointScale-pointScale)<0.001;
    [_leaseLock unlock];
    if (_cacheValid && cacheKeyMatches && now>=_cachedAt &&
        now-_cachedAt<kLGAppOwnedMaximumCacheAge) {
        NSUInteger index=0; uint64_t epoch=0;
        LGLocalButtonSourceContract contract={0}; id<MTLTexture> texture=nil;
        if (! [self acquireCacheAtTime:now index:&index epoch:&epoch contract:&contract texture:&texture]) {
            _lastStatus=LGAppOwnedButtonSourceStatusLeaseContention; return nil;
        }
        LGLocalButtonTextureFrame *frame=[self frameForSlot:index ownerGeneration:ownerGeneration
            epoch:epoch contract:contract texture:texture];
        _lastStatus=frame?LGAppOwnedButtonSourceStatusReady:LGAppOwnedButtonSourceStatusLeaseContention;
        return frame;
    }
    if (now<_lastCaptureAttempt) {
        _lastStatus=LGAppOwnedButtonSourceStatusInvalidConfiguration; return nil;
    }
    if (_hasCaptureAttempt && now-_lastCaptureAttempt<kLGAppOwnedMinimumCaptureInterval) {
        _lastStatus=LGAppOwnedButtonSourceStatusCaptureRateLimited; return nil;
    }

    NSUInteger slotIndex=0; uint64_t slotEpoch=0;
    LGAppOwnedTextureSlot *slot=[self reserveWritableSlot:&slotIndex epoch:&slotEpoch
        ownerGeneration:ownerGeneration];
    if (!slot) { _lastStatus=LGAppOwnedButtonSourceStatusLeaseContention; return nil; }
    _cacheValid=NO; _hasCaptureAttempt=YES; _lastCaptureAttempt=now;

    size_t bytesPerRow=(size_t)pixelWidth*4u;
    if (bytesPerRow/4u!=pixelWidth || (size_t)pixelHeight>SIZE_MAX/bytesPerRow) {
        [self abortWritableSlot:slot ownerGeneration:ownerGeneration epoch:slotEpoch];
        _lastStatus=LGAppOwnedButtonSourceStatusBitmapAllocationFailed; return nil;
    }
    size_t byteCount=bytesPerRow*(size_t)pixelHeight;
    uint8_t *bitmap=(uint8_t *)calloc(1,byteCount);
    CGColorSpaceRef colorSpace=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGBitmapInfo bitmapInfo=(CGBitmapInfo)(kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst);
    CGContextRef context=(bitmap&&colorSpace)?CGBitmapContextCreate(bitmap,pixelWidth,pixelHeight,
        8,bytesPerRow,colorSpace,bitmapInfo):NULL;
    if (!context) {
        if (colorSpace) CGColorSpaceRelease(colorSpace);
        free(bitmap); [self abortWritableSlot:slot ownerGeneration:ownerGeneration epoch:slotEpoch];
        _lastStatus=LGAppOwnedButtonSourceStatusBitmapAllocationFailed; return nil;
    }
    CGFloat renderScaleX=(CGFloat)pixelWidth/CGRectGetWidth(sourceRectInRoot);
    CGFloat renderScaleY=(CGFloat)pixelHeight/CGRectGetHeight(sourceRectInRoot);
    if (!isfinite(renderScaleX)||!isfinite(renderScaleY)||renderScaleX<0.25||renderScaleY<0.25||
        renderScaleX>16||renderScaleY>16) {
        CGContextRelease(context); CGColorSpaceRelease(colorSpace); free(bitmap);
        [self abortWritableSlot:slot ownerGeneration:ownerGeneration epoch:slotEpoch];
        _lastStatus=LGAppOwnedButtonSourceStatusUnsupportedTransform; return nil;
    }
    CGContextSetAllowsAntialiasing(context,true);
    CGContextTranslateCTM(context,0,(CGFloat)pixelHeight);
    CGContextScaleCTM(context,renderScaleX,-renderScaleY);
    CGContextTranslateCTM(context,-CGRectGetMinX(sourceRectInRoot),-CGRectGetMinY(sourceRectInRoot));
    CGContextClipToRect(context,sourceRectInRoot);
    BOOL renderSucceeded=NO;
    @try {
        [root.layer renderInContext:context];
        CGContextFlush(context);
        renderSucceeded=YES;
    } @catch (NSException *exception) {
        (void)exception; renderSucceeded=NO;
    }
    CGContextRelease(context); CGColorSpaceRelease(colorSpace);
    if (!renderSucceeded) {
        free(bitmap); [self abortWritableSlot:slot ownerGeneration:ownerGeneration epoch:slotEpoch];
        _lastStatus=LGAppOwnedButtonSourceStatusUnsupportedLayerContent; return nil;
    }

    BOOL allOpaque=YES;
    for (size_t i=3;i<byteCount;i+=4u) if (bitmap[i]!=255u) { allOpaque=NO; break; }
    if (!allOpaque) {
        free(bitmap); [self abortWritableSlot:slot ownerGeneration:ownerGeneration epoch:slotEpoch];
        _lastStatus=LGAppOwnedButtonSourceStatusTransparentCaptureRejected; return nil;
    }

    if ((uint32_t)MTLPixelFormatBGRA8Unorm_sRGB!=81u) {
        free(bitmap); [self abortWritableSlot:slot ownerGeneration:ownerGeneration epoch:slotEpoch];
        _lastStatus=LGAppOwnedButtonSourceStatusTextureAllocationFailed; return nil;
    }
    id<MTLTexture> texture=slot.texture;
    if (!texture || texture.width!=pixelWidth || texture.height!=pixelHeight ||
        texture.pixelFormat!=MTLPixelFormatBGRA8Unorm_sRGB || texture.device!=_device ||
        texture.textureType!=MTLTextureType2D || texture.sampleCount!=1 ||
        !(texture.usage&MTLTextureUsageShaderRead)) {
        MTLTextureDescriptor *descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
            MTLPixelFormatBGRA8Unorm_sRGB width:pixelWidth height:pixelHeight mipmapped:NO];
        descriptor.textureType=MTLTextureType2D;
        descriptor.usage=MTLTextureUsageShaderRead;
        descriptor.storageMode=MTLStorageModeShared;
        texture=[_device newTextureWithDescriptor:descriptor];
    }
    if (!texture || texture.width!=pixelWidth || texture.height!=pixelHeight ||
        texture.pixelFormat!=MTLPixelFormatBGRA8Unorm_sRGB || texture.device!=_device ||
        texture.textureType!=MTLTextureType2D || texture.sampleCount!=1 ||
        !(texture.usage&MTLTextureUsageShaderRead)) {
        free(bitmap); [self abortWritableSlot:slot ownerGeneration:ownerGeneration epoch:slotEpoch];
        _lastStatus=LGAppOwnedButtonSourceStatusTextureAllocationFailed; return nil;
    }
    MTLRegion region=MTLRegionMake2D(0,0,pixelWidth,pixelHeight);
    [texture replaceRegion:region mipmapLevel:0 withBytes:bitmap bytesPerRow:bytesPerRow];
    free(bitmap);

    if (_frameGeneration==UINT64_MAX) {
        [self abortWritableSlot:slot ownerGeneration:ownerGeneration epoch:slotEpoch];
        _lastStatus=LGAppOwnedButtonSourceStatusOwnerUnavailable; return nil;
    }
    LGLocalButtonSourceContract contract={0};
    contract.sourceRectInOwnerPoints=sourceRect;
    contract.targetRectInOwnerPoints=targetRect;
    contract.textureWidth=pixelWidth; contract.textureHeight=pixelHeight;
    contract.pixelFormat=(uint32_t)MTLPixelFormatBGRA8Unorm_sRGB;
    contract.pointScale=(float)pointScale;
    contract.ownerInstanceToken=_ownerToken;
    contract.ownerGeneration=ownerGeneration;
    contract.frameGeneration=++_frameGeneration;
    contract.targetGeometryGeneration=_targetGeometryGeneration;
    contract.frameTimestampMonotonic=now;
    contract.sourceKind=LGLocalSourceLiveAppOwnedTexture;
    contract.alphaMode=LGLocalAlphaOpaque;
    contract.maskKind=LGLocalMaskRounded44;
    contract.backgroundOnly=true; contract.targetForegroundExcluded=true;
    contract.immutableUntilFrameReleased=true;
    /* sRGB texture sampling linearizes stored sRGB RGB; alpha==1 makes the
     * byte-domain premultiplication claim exact rather than inferred. */
    contract.sampledRGBIsLinear=true; contract.sampledRGBIsPremultiplied=true;
    contract.sourceOverscanEnabled=(_edgePadding.top>0||_edgePadding.left>0||
        _edgePadding.bottom>0||_edgePadding.right>0);

    [_leaseLock lock];
    slot.texture=texture; slot.contract=contract; slot.rootBounds=root.bounds;
    slot.rootBoundsInParent=rootBoundsInParent; slot.sourceRectInRoot=sourceRectInRoot;
    slot.dirtyGeneration=_dirtyGeneration;
    BOOL published=LGAppOwnedLeasePublish(&slot->leasePolicy,ownerGeneration,slotEpoch);
    [_leaseLock unlock];
    if (!published) {
        [self abortWritableSlot:slot ownerGeneration:ownerGeneration epoch:slotEpoch];
        _lastStatus=LGAppOwnedButtonSourceStatusLeaseContention; return nil;
    }
    _cachedSlotIndex=slotIndex; _cachedSlotEpoch=slotEpoch; _cachedAt=now;
    _cachedTargetRect=targetRect; _hasCachedTargetRect=YES;
    _lastSuccessfulTargetGeometryGeneration=_targetGeometryGeneration;
    _cacheValid=YES;
    LGLocalButtonTextureFrame *frame=[self frameForSlot:slotIndex ownerGeneration:ownerGeneration
        epoch:slotEpoch contract:contract texture:texture];
    _lastStatus=frame?LGAppOwnedButtonSourceStatusReady:LGAppOwnedButtonSourceStatusLeaseContention;
    return frame;
}

@end
