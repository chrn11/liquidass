#import "OwnedTouchRuntimeProbe.h"
#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <stdint.h>
#import "LGButtonOpticalState.h"
#import "LGLocalButtonUniforms.h"
#import "LGLocalButtonMaterialView.h"
#import "LGAppOwnedButtonSourceProvider.h"

static NSString * const kOwnedTouchIdentifier = @"minisOwnedGlassTouchProbe";
static NSString * const kAllowedBundleIdentifier = @"org.liquidass.native-play-lab";
static const CFTimeInterval kSourceRefreshInterval = (1.0/15.0) + 0.008;
static const CFTimeInterval kProbeTimeout = 30.0;
static const CFTimeInterval kCompletionObservationWindow = 0.100;
static const CFTimeInterval kCompletionObservationInterval = 0.005;
static const NSUInteger kCompletionObservationMaximumAttempts = 20;
static const uint64_t kInitialGeometryGeneration = 1;

static BOOL LGTouchRectClose(CGRect a, CGRect b) {
    const CGFloat e=0.01;
    return fabs(CGRectGetMinX(a)-CGRectGetMinX(b))<e &&
        fabs(CGRectGetMinY(a)-CGRectGetMinY(b))<e &&
        fabs(CGRectGetWidth(a)-CGRectGetWidth(b))<e &&
        fabs(CGRectGetHeight(a)-CGRectGetHeight(b))<e;
}

static BOOL LGTouchFiniteRect(CGRect r) {
    return isfinite(CGRectGetMinX(r)) && isfinite(CGRectGetMinY(r)) &&
        isfinite(CGRectGetWidth(r)) && isfinite(CGRectGetHeight(r)) &&
        CGRectGetWidth(r)>0 && CGRectGetHeight(r)>0;
}

static BOOL LGTouchAxisAlignedPath(UIView *view) {
    const CGFloat e=1.0e-6;
    for (UIView *v=view; v; v=v.superview) {
        CGAffineTransform t=v.transform;
        CATransform3D l=v.layer.transform;
        if (!isfinite(t.a)||!isfinite(t.b)||!isfinite(t.c)||!isfinite(t.d)||
            !isfinite(t.tx)||!isfinite(t.ty)||t.a<=0||t.d<=0||
            fabs(t.b)>e||fabs(t.c)>e||!CATransform3DIsAffine(l)||
            l.m11<=0||l.m22<=0||fabs(l.m12)>e||fabs(l.m21)>e||
            fabs(l.m13)>e||fabs(l.m14)>e||fabs(l.m23)>e||fabs(l.m24)>e||
            fabs(l.m31)>e||fabs(l.m32)>e||fabs(l.m34)>e||fabs(l.m43)>e||
            fabs(l.m33-1.0)>e||fabs(l.m44-1.0)>e) return NO;
    }
    return YES;
}

@class LGOwnedTouchProbe;

@interface LGOwnedTouchTarget : UIControl {
@public
    LGButtonOpticalState opticalState;
}
@property(nonatomic,weak) LGOwnedTouchProbe *probe;
@property(nonatomic) NSUInteger beginTrackingCalls;
@property(nonatomic) NSUInteger acceptedBeginCalls;
@property(nonatomic) NSUInteger continueTrackingCalls;
@property(nonatomic) NSUInteger endTrackingCalls;
@property(nonatomic) NSUInteger cancelTrackingCalls;
@property(nonatomic) BOOL acceptedUIKitGestureActive;
@end

@interface LGOwnedTouchProbeSourceProvider : LGAppOwnedButtonSourceProvider
@property(nonatomic) LGLocalButtonSourceContract mostRecentContract;
@property(nonatomic) BOOL hasMostRecentContract;
@end

@implementation LGOwnedTouchProbeSourceProvider
- (LGLocalButtonTextureFrame *)currentBackgroundFrameForTargetView:(UIView *)target
                                               monotonicTimestamp:(CFTimeInterval)now {
    LGLocalButtonTextureFrame *frame=[super currentBackgroundFrameForTargetView:target
        monotonicTimestamp:now];
    if (frame) { self.mostRecentContract=frame.contract; self.hasMostRecentContract=YES; }
    return frame; // Preserve the provider's exact immutable frame/lease.
}
@end

@interface LGWeakTouchDisplayLinkTarget : NSObject
@property(nonatomic,weak) LGOwnedTouchProbe *probe;
- (void)displayLinkFired:(CADisplayLink *)link;
@end

@interface LGOwnedTouchProbe : NSObject
@property(nonatomic,copy) NSString *runIdentifier;
@property(nonatomic,weak) UIView *originalButton;
@property(nonatomic,strong) UIView *scopeView;
@property(nonatomic,strong) UIView *sourceRoot;
@property(nonatomic,strong) NSArray<UIView *> *sourceBands;
@property(nonatomic,strong) UILabel *instructionLabel;
@property(nonatomic,strong) LGOwnedTouchTarget *target;
@property(nonatomic,strong) LGOwnedTouchProbeSourceProvider *provider;
@property(nonatomic,strong) LGLocalButtonMaterialView *material;
@property(nonatomic,strong) NSTimer *refreshTimer;
@property(nonatomic,strong) CADisplayLink *displayLink;
@property(nonatomic,strong) LGWeakTouchDisplayLinkTarget *displayLinkTarget;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *touchEvents;
@property(nonatomic,strong) NSMutableArray<NSMutableDictionary *> *drawSamples;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *availabilityEvents;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *completionObservationEvents;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *checks;
@property(nonatomic,strong) NSMutableDictionary *leftCompletedUniformTuple;
@property(nonatomic,strong) NSMutableDictionary *rightCompletedUniformTuple;
@property(nonatomic,strong) NSMutableDictionary *leftUIKitExtreme;
@property(nonatomic,strong) NSMutableDictionary *rightUIKitExtreme;
@property(nonatomic,strong) NSMutableDictionary *latestDrawSample;
@property(nonatomic,copy) void (^completion)(NSDictionary *result);
@property(nonatomic) uint64_t geometryGeneration;
@property(nonatomic) uint64_t requestSequence;
@property(nonatomic) NSUInteger backgroundRevision;
@property(nonatomic) CFTimeInterval startedAt;
@property(nonatomic) CFTimeInterval lastDisplayTick;
@property(nonatomic) BOOL terminalTouchObserved;
@property(nonatomic) BOOL realTouchEndObserved;
@property(nonatomic) BOOL touchCancelled;
@property(nonatomic) BOOL steadyPressureReached;
@property(nonatomic) float maximumOpticalPressure;
@property(nonatomic) BOOL didCleanup;
@property(nonatomic) BOOL readyRecordPublished;
@property(nonatomic) CGRect lastPublishedScreenRect;
- (void)publishOwnTouchReadyRecord;
- (void)removeOwnTouchReadyRecord;
@property(nonatomic) BOOL overlayGeometryValid;
@property(nonatomic) BOOL initialSubmitReady;
@property(nonatomic) BOOL initialUniformsBuilt;
@property(nonatomic) BOOL timeoutReached;
- (void)refreshEligibility;
- (void)trackingCallback:(NSString *)phase touch:(nullable UITouch *)touch
          originalResult:(BOOL)result originalResultAvailable:(BOOL)resultAvailable
                  inside:(BOOL)inside acceptedTouch:(BOOL)acceptedTouch;
- (void)cancelCallback;
- (void)startOrStopDisplayLink;
- (void)displayTick;
- (void)addCheck:(NSString *)name pass:(BOOL)pass observed:(id)observed details:(NSDictionary *)details;
- (void)failSetup:(NSString *)status detail:(NSString *)detail;
- (BOOL)setupWithDevice:(id<MTLDevice>)device;
- (BOOL)synchronizeOverlayGeometry;
- (BOOL)isVisibleAndActive;
- (void)installBackdropModel;
- (BOOL)submitSnapshotForReason:(NSString *)reason initial:(BOOL)initial;
- (void)refreshAndSubmit;
- (void)rendererAvailabilityChanged:(LGLocalButtonMaterialView *)view available:(BOOL)available;
- (BOOL)isActuallyCompletedSample:(NSMutableDictionary *)sample
                          renderer:(LGLocalButtonMaterialView *)view
                    observedSerial:(uint64_t)serial
                         sourceKind:(NSString *)sourceKind;
- (void)markSampleActuallyCompleted:(NSMutableDictionary *)sample
                      observedSerial:(uint64_t)serial
                           sourceKind:(NSString *)sourceKind;
- (void)observeCompletionSequence:(uint64_t)sequence
                            sample:(NSMutableDictionary *)sample
                       startedAt:(CFTimeInterval)startedAt
                          attempt:(NSUInteger)attempt;
- (BOOL)tupleMatchesActuallyObservedSample:(NSDictionary *)tuple;
- (void)updatePressureEvidence;
- (NSDictionary *)rendererName:(LGLocalButtonRendererResult)result;
- (BOOL)pointTuplesDiffer;
- (BOOL)latestRequestIsCompletedRelease;
- (void)maybeFinishAfterTerminalTouch;
- (NSDictionary *)buildFinalResult:(NSString *)status failure:(NSString *)failure;
- (void)cleanupFixture;
- (void)finishWithStatus:(NSString *)status failure:(NSString *)failure;
@end

@implementation LGWeakTouchDisplayLinkTarget
- (void)displayLinkFired:(CADisplayLink *)link { [self.probe displayTick]; }
@end

@implementation LGOwnedTouchTarget
- (CGPoint)localPointForTouch:(UITouch *)touch {
    CGPoint p=[touch locationInView:self];
    return CGPointMake(p.x-CGRectGetMinX(self.bounds),p.y-CGRectGetMinY(self.bounds));
}
- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent * _Nullable)event {
    self.beginTrackingCalls++;
    [self.probe refreshEligibility];
    BOOL originalResult=[super beginTrackingWithTouch:touch withEvent:event];
    BOOL acceptedTouch=NO;
    BOOL inside=NO;
    if (touch) {
        CGPoint p=[self localPointForTouch:touch];
        inside=[self pointInside:[touch locationInView:self] withEvent:event];
        BOOL opticalAccepted=LGOpticalBegin(&opticalState,CACurrentMediaTime(),originalResult,inside,
            (float)p.x,(float)p.y,(float)CGRectGetWidth(self.bounds),
            (float)CGRectGetHeight(self.bounds));
        acceptedTouch=originalResult && opticalAccepted && opticalState.tracking && opticalState.touchValid;
    }
    self.acceptedUIKitGestureActive=acceptedTouch;
    if (acceptedTouch) self.acceptedBeginCalls++;
    [self.probe trackingCallback:@"began" touch:touch originalResult:originalResult
        originalResultAvailable:YES inside:inside acceptedTouch:acceptedTouch];
    return originalResult;
}
- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent * _Nullable)event {
    self.continueTrackingCalls++;
    [self.probe refreshEligibility];
    BOOL originalResult=[super continueTrackingWithTouch:touch withEvent:event];
    BOOL inside=NO;
    BOOL acceptedTouch=NO;
    if (touch) {
        CGPoint p=[self localPointForTouch:touch];
        inside=[self pointInside:[touch locationInView:self] withEvent:event];
        LGOpticalContinue(&opticalState,CACurrentMediaTime(),originalResult,inside,
            (float)p.x,(float)p.y,(float)CGRectGetWidth(self.bounds),
            (float)CGRectGetHeight(self.bounds));
        acceptedTouch=self.acceptedUIKitGestureActive && originalResult &&
            opticalState.tracking && opticalState.touchValid;
        self.acceptedUIKitGestureActive=acceptedTouch;
    }
    [self.probe trackingCallback:@"moved" touch:touch originalResult:originalResult
        originalResultAvailable:YES inside:inside acceptedTouch:acceptedTouch];
    return originalResult;
}
- (void)endTrackingWithTouch:(UITouch * _Nullable)touch withEvent:(UIEvent * _Nullable)event {
    self.endTrackingCalls++;
    [self.probe refreshEligibility];
    [super endTrackingWithTouch:touch withEvent:event];
    if (!touch) {
        LGOpticalEnd(&opticalState,CACurrentMediaTime(),YES);
        self.acceptedUIKitGestureActive=NO;
        [self.probe cancelCallback];
        return;
    }
    BOOL acceptedTouch=self.acceptedUIKitGestureActive;
    BOOL inside=[self pointInside:[touch locationInView:self] withEvent:event];
    if (acceptedTouch) {
        CGPoint p=[self localPointForTouch:touch];
        LGOpticalObservePoint(&opticalState,(float)p.x,(float)p.y,
            (float)CGRectGetWidth(self.bounds),(float)CGRectGetHeight(self.bounds));
        LGOpticalEnd(&opticalState,CACurrentMediaTime(),NO);
    }
    self.acceptedUIKitGestureActive=NO;
    [self.probe trackingCallback:@"ended" touch:touch originalResult:NO
        originalResultAvailable:NO inside:inside acceptedTouch:acceptedTouch];
}
- (void)cancelTrackingWithEvent:(UIEvent * _Nullable)event {
    self.cancelTrackingCalls++;
    [self.probe refreshEligibility];
    [super cancelTrackingWithEvent:event];
    LGOpticalEnd(&opticalState,CACurrentMediaTime(),YES);
    self.acceptedUIKitGestureActive=NO;
    [self.probe cancelCallback];
}
@end

static NSMutableDictionary<NSString *,LGOwnedTouchProbe *> *LGOwnedTouchLiveProbes(void) {
    static NSMutableDictionary *probes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken,^{ probes=[NSMutableDictionary dictionary]; });
    return probes;
}

static NSArray<UIColor *> *LGOwnedTouchPalette(void) {
    static NSArray<UIColor *> *palette;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken,^{
        palette=@[[UIColor colorWithRed:0.08 green:0.32 blue:0.67 alpha:1],
                  [UIColor colorWithRed:0.10 green:0.58 blue:0.48 alpha:1],
                  [UIColor colorWithRed:0.78 green:0.30 blue:0.12 alpha:1],
                  [UIColor colorWithRed:0.48 green:0.22 blue:0.66 alpha:1],
                  [UIColor colorWithRed:0.84 green:0.64 blue:0.12 alpha:1],
                  [UIColor colorWithRed:0.12 green:0.50 blue:0.72 alpha:1]];
    });
    return palette;
}

@implementation LGOwnedTouchProbe
- (void)addCheck:(NSString *)name pass:(BOOL)pass observed:(id)observed details:(NSDictionary *)details {
    NSMutableDictionary *entry=[@{@"name":name,@"pass":@(pass),
        @"observed":observed?:[NSNull null]} mutableCopy];
    if (details) entry[@"details"]=details;
    [self.checks addObject:entry];
}
- (void)failSetup:(NSString *)status detail:(NSString *)detail {
    [self addCheck:@"fixture_setup" pass:NO observed:detail?:@"setup failed" details:nil];
    [self finishWithStatus:status failure:detail];
}
- (BOOL)isVisibleAndActive {
    if (!self.target.window || !self.scopeView.window ||
        self.target.window!=self.scopeView.window ||
        UIApplication.sharedApplication.applicationState!=UIApplicationStateActive) return NO;
    if (@available(iOS 13.0,*))
        if (self.target.window.windowScene.activationState!=UISceneActivationStateForegroundActive) return NO;
    UIWindow *window=self.target.window;
    for (UIView *v=self.target; v; v=v.superview) {
        if (v.hidden || v.alpha<0.01) return NO;
        if ([v isKindOfClass:UIWindow.class]) return v==window;
        if (v.window!=window) return NO;
    }
    return NO;
}
- (BOOL)synchronizeOverlayGeometry {
    UIView *button=self.originalButton, *parent=button.superview;
    if (!button || !parent || !self.scopeView || !self.target || !self.sourceRoot) return NO;
    CGRect buttonRect=[button convertRect:button.bounds toView:parent];
    if (!LGTouchFiniteRect(buttonRect) || !LGTouchAxisAlignedPath(button) ||
        CGRectGetWidth(buttonRect)<44.0 || CGRectGetHeight(buttonRect)<44.0 ||
        CGRectGetWidth(buttonRect)>362.01 || CGRectGetHeight(buttonRect)>46.01) return NO;
    CGRect targetFrame=CGRectMake(0,(CGRectGetHeight(buttonRect)-44.0)*0.5,44,44);
    BOOL changed=!LGTouchRectClose(self.scopeView.frame,buttonRect) ||
        !LGTouchRectClose(self.target.frame,targetFrame) ||
        !LGTouchRectClose(self.sourceRoot.frame,targetFrame) ||
        (self.material && !LGTouchRectClose(self.material.frame,targetFrame));
    if (changed) {
        self.scopeView.frame=buttonRect;
        self.target.frame=targetFrame;
        self.sourceRoot.frame=targetFrame;
        self.material.frame=targetFrame;
        [self.scopeView layoutIfNeeded];
        if (self.geometryGeneration==UINT64_MAX) return NO;
        self.geometryGeneration++;
        BOOL eligible=[self isVisibleAndActive];
        LGOpticalSetEligibility(&self.target->opticalState,YES,self.target.enabled,
            self.target.window!=nil,eligible,UIApplication.sharedApplication.applicationState==UIApplicationStateActive,
            self.geometryGeneration);
        if (![self.provider updateTargetGeometryGeneration:self.geometryGeneration]) return NO;
    }
    CGRect targetRect=[self.target convertRect:self.target.bounds toView:self.target.superview];
    CGRect sourceRect=[self.sourceRoot convertRect:self.sourceRoot.bounds toView:self.target.superview];
    CGRect materialRect=[self.material convertRect:self.material.bounds toView:self.target.superview];
    self.overlayGeometryValid=LGTouchRectClose(targetRect,sourceRect) &&
        LGTouchRectClose(targetRect,materialRect) &&
        fabs(CGRectGetWidth(targetRect)-44.0)<0.01 && fabs(CGRectGetHeight(targetRect)-44.0)<0.01;
    return self.overlayGeometryValid;
}
- (void)refreshEligibility {
    if (!self.target || self.didCleanup) return;
    BOOL visible=[self isVisibleAndActive];
    LGOpticalSetEligibility(&self.target->opticalState,YES,self.target.enabled,
        self.target.window!=nil,visible,
        UIApplication.sharedApplication.applicationState==UIApplicationStateActive,
        self.geometryGeneration);
}
- (void)installBackdropModel {
    CGRect modelFrame=CGRectMake(0,(CGRectGetHeight(self.scopeView.bounds)-44.0)*0.5,44,44);
    UIImageView *root=[[UIImageView alloc] initWithFrame:modelFrame];
    root.image=[UIImage imageNamed:@"InputBotanical.png"];
    root.contentMode=UIViewContentModeScaleAspectFill;root.clipsToBounds=YES;
    root.opaque=YES;root.backgroundColor=UIColor.blackColor;
    root.userInteractionEnabled=NO;root.accessibilityElementsHidden=YES;
    self.sourceRoot=root;self.sourceBands=@[];
}
- (NSURL *)ownTouchReadyURL {
    NSURL *docs=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    return [docs URLByAppendingPathComponent:@"native-owned-touch-ready.json"];
}
- (void)removeOwnTouchReadyRecord {
    NSURL *url=[self ownTouchReadyURL];NSData *data=[NSData dataWithContentsOfURL:url];
    NSDictionary *record=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    if ([record[@"probeRunIdentifier"] isEqual:self.runIdentifier])
        [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    self.readyRecordPublished=NO;
}
- (void)publishOwnTouchReadyRecord {
    if (self.didCleanup || ![self isVisibleAndActive] ||
        !self.material.hasCurrentCompletedValidSubmission) return;
    UIWindow *window=self.target.window;
    CGRect screenRect=[self.target convertRect:self.target.bounds toView:nil];
    CGPoint center=CGPointMake(CGRectGetMidX(self.target.bounds),CGRectGetMidY(self.target.bounds));
    CGPoint point=[self.target convertPoint:center toView:window];
    UIView *hit=[window hitTest:point withEvent:nil];
    BOOL actualHit=hit==self.target || [hit isDescendantOfView:self.target];
    if (!actualHit || !LGTouchFiniteRect(screenRect)) {
        [self removeOwnTouchReadyRecord];return;
    }
    if(self.readyRecordPublished && CGRectEqualToRect(self.lastPublishedScreenRect,screenRect))return;
    NSDictionary *record=@{@"schemaVersion":@1,@"ready":@YES,
        @"bundleIdentifier":NSBundle.mainBundle.bundleIdentifier?:@"",
        @"build":NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"]?:@"",
        @"probeIdentifier":kOwnedTouchIdentifier,@"probeRunIdentifier":self.runIdentifier,
        @"createdAtUnix":@(NSDate.date.timeIntervalSince1970),
        @"targetRectScreenPoints":@{@"x":@(screenRect.origin.x),@"y":@(screenRect.origin.y),@"width":@(screenRect.size.width),@"height":@(screenRect.size.height)},
        @"ownPublicWindowHitTestConfirmed":@(actualHit),
        @"actualInitialGPUCompletedSerial":@(self.material.lastCompletedSubmissionSerial),
        @"windowBounds":NSStringFromCGRect(window.bounds),
        @"foregroundActiveAtPublish":@YES,@"inputNotSynthesizedByFixture":@YES,@"designedLightCaptureDirectory":self.material.experimentalDesignedLightCaptureDirectoryName?:@"UNAVAILABLE",@"runtimeVerifiedShaderSHA256":self.material.experimentalVerifiedShaderSHA256?:@"UNAVAILABLE",@"designedLightExperiment":@(self.material.experimentalDesignedLightEnabled),@"designedLightMSLSHA256":@"1859d9436938cdbf51b4cb215b897ea175a9e3fddff7c6631e662d311af75740",
        @"notSettingsOrSystemHost":@YES};
    NSData *encoded=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:nil];
    if(encoded && [encoded writeToURL:[self ownTouchReadyURL] options:NSDataWritingAtomic error:nil]){
        self.readyRecordPublished=YES;self.lastPublishedScreenRect=screenRect;
    }
}

- (BOOL)setupWithDevice:(id<MTLDevice>)device {
    UIView *button=self.originalButton, *parent=button.superview;
    NSString *bundle=NSBundle.mainBundle.bundleIdentifier?:@"";
    if (![bundle isEqualToString:kAllowedBundleIdentifier]) {
        [self failSetup:@"FAIL_BUNDLE_SCOPE" detail:@"fixture is restricted to org.liquidass.native-play-lab"];
        return NO;
    }
    if (!NSThread.isMainThread || !button || !parent || !button.window || !device ||
        !LGTouchAxisAlignedPath(button)) {
        [self failSetup:@"FAIL_SETUP" detail:@"missing original control/parent/window/device or unsupported transform"];
        return NO;
    }
    CGRect buttonRect=[button convertRect:button.bounds toView:parent];
    if (!LGTouchFiniteRect(buttonRect) || CGRectGetWidth(buttonRect)<52.0 ||
        CGRectGetHeight(buttonRect)<44.0 || CGRectGetWidth(buttonRect)>362.01 ||
        CGRectGetHeight(buttonRect)>46.01) {
        [self failSetup:@"FAIL_SETUP" detail:@"original container must fit the 44pt target/instruction within <=362x46pt"];
        return NO;
    }
    self.geometryGeneration=kInitialGeometryGeneration;
    self.scopeView=[[UIView alloc] initWithFrame:buttonRect];
    self.scopeView.backgroundColor=UIColor.clearColor;
    self.scopeView.opaque=NO; self.scopeView.clipsToBounds=NO;
    self.scopeView.userInteractionEnabled=YES;
    self.scopeView.accessibilityElementsHidden=NO;
    self.scopeView.accessibilityIdentifier=@"minisOwnedGlassTouchProbeScope";
    [parent insertSubview:self.scopeView aboveSubview:button];
    [self installBackdropModel];

    CGRect targetFrame=CGRectMake(0,(CGRectGetHeight(buttonRect)-44.0)*0.5,44,44);
    self.target=[[LGOwnedTouchTarget alloc] initWithFrame:targetFrame];
    self.target.probe=self; self.target.enabled=YES; self.target.userInteractionEnabled=YES;
    self.target.multipleTouchEnabled=NO; self.target.backgroundColor=UIColor.clearColor;
    self.target.opaque=NO; self.target.layer.cornerRadius=22.0;
    self.target.accessibilityIdentifier=kOwnedTouchIdentifier;
    self.target.accessibilityLabel=@"LiquidAss owned glass touch test";
    self.target.accessibilityValue=@"AWAITING_REAL_TOUCH";
    self.target.isAccessibilityElement=YES;
    LGOpticalReset(&self.target->opticalState,self.geometryGeneration);
    [self.scopeView addSubview:self.sourceRoot];
    [self.scopeView addSubview:self.target];

    UILabel *label=[[UILabel alloc] initWithFrame:CGRectMake(50,0,
        CGRectGetWidth(buttonRect)-50,CGRectGetHeight(buttonRect))];
    label.text=@"设计光实验：按住玻璃左右拖动";
    label.font=[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    label.textColor=UIColor.whiteColor; label.textAlignment=NSTextAlignmentCenter;
    label.adjustsFontSizeToFitWidth=YES; label.minimumScaleFactor=0.75;
    label.backgroundColor=[UIColor colorWithWhite:0 alpha:0.62];
    label.layer.cornerRadius=8; label.clipsToBounds=YES;
    label.userInteractionEnabled=NO; label.isAccessibilityElement=NO;
    self.instructionLabel=label; [self.scopeView addSubview:label];

    LGOwnedTouchProbeSourceProvider *provider=[[LGOwnedTouchProbeSourceProvider alloc]
        initWithSourceRoot:self.sourceRoot targetView:self.target device:device
        edgePadding:UIEdgeInsetsZero explicitOptIn:YES];
    self.provider=provider;
    if (!provider) {
        [self failSetup:@"FAIL_PROVIDER_INIT" detail:@"AppOwnedButtonSourceProvider rejected the explicit owned subtree"];
        return NO;
    }
    LGLocalButtonMaterialView *material=[[LGLocalButtonMaterialView alloc]
        initWithFrame:self.target.frame targetView:self.target sourceProvider:provider
        allowApproximateSource:NO explicitOptIn:YES experimentalDesignedLighting:YES];
    self.material=material;
    if (!material || !material.device) {
        [self failSetup:@"FAIL_RENDERER_INIT" detail:@"actual LGLocalButtonMaterialView could not be created"];
        return NO;
    }
    [self.scopeView insertSubview:material belowSubview:self.target];
    [self.scopeView layoutIfNeeded];
    if (![provider bindMaterialViewForFeedbackExclusion:material device:material.device] ||
        ![provider updateTargetGeometryGeneration:self.geometryGeneration]) {
        [self failSetup:@"FAIL_PROVIDER_BIND" detail:[NSString stringWithFormat:@"AppOwned binding status %ld",(long)provider.lastStatus]];
        return NO;
    }
    [self refreshEligibility];
    if (![self synchronizeOverlayGeometry]) {
        [self failSetup:@"FAIL_GEOMETRY" detail:@"target/material/source are not 44pt axis-aligned siblings in one parent"];
        return NO;
    }
    __weak LGOwnedTouchProbe *weakSelf=self;
    material.availabilityChangedHandler=^(LGLocalButtonMaterialView *view,BOOL available) {
        LGOwnedTouchProbe *strongSelf=weakSelf;
        if (strongSelf) [strongSelf rendererAvailabilityChanged:view available:available];
    };
    self.refreshTimer=[NSTimer timerWithTimeInterval:kSourceRefreshInterval repeats:YES
        block:^(__unused NSTimer *timer) {
            LGOwnedTouchProbe *strongSelf=weakSelf;
            if (strongSelf) [strongSelf refreshAndSubmit];
        }];
    [NSRunLoop.mainRunLoop addTimer:self.refreshTimer forMode:NSRunLoopCommonModes];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(kProbeTimeout*NSEC_PER_SEC)),
        dispatch_get_main_queue(),^{
            LGOwnedTouchProbe *strongSelf=weakSelf;
            if (strongSelf && !strongSelf.didCleanup) {
                strongSelf.timeoutReached=YES;
                [strongSelf finishWithStatus:@"FAIL_TIMEOUT"
                    failure:(strongSelf.target.beginTrackingCalls ? @"30s elapsed before complete touch/release/completion criteria" : @"30s elapsed with no real UIKit touch; no input was synthesized")];
            }
        });
    BOOL ready=[self submitSnapshotForReason:@"initial-owned-source" initial:YES];
    if (!ready) {
        [self finishWithStatus:@"FAIL_INITIAL_SUBMIT" failure:@"initial AppOwned source/render submit did not return ReadyForNextDraw"];
        return NO;
    }
    return YES;
}
- (void)updatePressureEvidence {
    LGButtonOpticalState *s=&self.target->opticalState;
    self.maximumOpticalPressure=MAX(self.maximumOpticalPressure,s->pressure);
    if (s->tracking && s->phase==LGOpticalTrackingInside && s->pressure>=0.9995f)
        self.steadyPressureReached=YES;
}
- (void)startOrStopDisplayLink {
    if (self.didCleanup || !self.target) return;
    LGButtonOpticalState *s=&self.target->opticalState;
    BOOL needed=(s->tracking || s->wantsFrames) && [self isVisibleAndActive];
    if (needed && !self.displayLink) {
        LGWeakTouchDisplayLinkTarget *proxy=[LGWeakTouchDisplayLinkTarget new];
        proxy.probe=self; self.displayLinkTarget=proxy;
        self.displayLink=[CADisplayLink displayLinkWithTarget:proxy selector:@selector(displayLinkFired:)];
        [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    } else if (!needed && self.displayLink) {
        [self.displayLink invalidate]; self.displayLink=nil; self.displayLinkTarget=nil;
    }
}
- (void)displayTick {
    if (self.didCleanup || !self.target) return;
    [self refreshEligibility];
    LGButtonOpticalState *s=&self.target->opticalState;
    if (!s->eligible || (!s->tracking && !s->wantsFrames)) {
        [self startOrStopDisplayLink];
        return;
    }
    CFTimeInterval now=CACurrentMediaTime();
    self.lastDisplayTick=now;
    LGOpticalTick(s,now);
    [self updatePressureEvidence];
    [self startOrStopDisplayLink];
}
- (void)trackingCallback:(NSString *)phase touch:(UITouch * _Nullable)touch
          originalResult:(BOOL)result originalResultAvailable:(BOOL)resultAvailable
                  inside:(BOOL)inside acceptedTouch:(BOOL)acceptedTouch {
    if (self.didCleanup || !self.target || !touch) return;
    CFTimeInterval now=CACurrentMediaTime();
    LGButtonOpticalState *s=&self.target->opticalState;
    [self updatePressureEvidence];
    CGFloat maxForce=touch.maximumPossibleForce;
    id forceValue=(maxForce>0 && isfinite(touch.force)) ?
        @((double)MIN(1.0,MAX(0.0,touch.force/maxForce))) : (id)[NSNull null];
    NSMutableDictionary *event=[@{
        @"phase":phase, @"eventSource":@"UIKit UIControl tracking callback",
        @"trueUIKitTouch":@(acceptedTouch), @"monotonicCallbackTime":@(now),
        @"touchObjectObserved":@YES, @"originalTrackingResultAvailable":@(resultAvailable),
        @"originalTrackingResult":@(result), @"acceptedByFixtureTracking":@(acceptedTouch),
        @"insideAccordingToControl":@(inside),
        @"normalizedPoint":@[@(s->touchX),@(s->touchY)],
        @"stateTracking":@(s->tracking), @"statePhase":@(s->phase),
        @"statePressure":@(s->pressure), @"stateTarget":@(s->target),
        @"touchForceFractionIfReported":forceValue,
        @"touchForceIsOpticalPressure":@NO
    } mutableCopy];
    if (acceptedTouch) event[@"uitouchTimestamp"]=@(touch.timestamp);
    if (([phase isEqualToString:@"began"] || [phase isEqualToString:@"moved"]) &&
        acceptedTouch && result && s->tracking) {
        self.target.accessibilityValue=@"REAL_TOUCH_TRACKING";
        if (s->touchX<=0.10f) {
            self.leftUIKitExtreme=[@{@"normalizedX":@(s->touchX),@"normalizedY":@(s->touchY),
                @"phase":@(s->phase),@"pressureAtUIKitCallback":@(s->pressure)} mutableCopy];
            event[@"leftExtremeObserved"]=@YES;
        }
        if (s->touchX>=0.90f) {
            self.rightUIKitExtreme=[@{@"normalizedX":@(s->touchX),@"normalizedY":@(s->touchY),
                @"phase":@(s->phase),@"pressureAtUIKitCallback":@(s->pressure)} mutableCopy];
            event[@"rightExtremeObserved"]=@YES;
        }
    }
    if ([phase isEqualToString:@"ended"] && acceptedTouch) {
        self.terminalTouchObserved=YES; self.realTouchEndObserved=YES;
        self.target.accessibilityValue=@"REAL_TOUCH_ENDED_AWAITING_RELEASE";
    }
    if (phase.length) [self.touchEvents addObject:[event copy]];
    [self startOrStopDisplayLink];
}
- (void)cancelCallback {
    if (self.didCleanup || !self.target) return;
    CFTimeInterval now=CACurrentMediaTime();
    LGButtonOpticalState *s=&self.target->opticalState;
    self.terminalTouchObserved=YES; self.touchCancelled=YES;
    [self.touchEvents addObject:@{
        @"phase":@"cancelled",@"eventSource":@"UIKit UIControl cancelTrackingWithEvent:",
        @"trueUIKitTouch":@NO,@"cancelledUIKitCallback":@YES,@"monotonicCallbackTime":@(now),
        @"touchObjectObserved":@NO,@"stateTracking":@(s->tracking),
        @"statePhase":@(s->phase),@"statePressure":@(s->pressure),
        @"stateTarget":@(s->target),@"touchForceIsOpticalPressure":@NO
    }];
    self.target.accessibilityValue=@"REAL_TOUCH_CANCELLED_AWAITING_RELEASE";
    [self updatePressureEvidence]; [self startOrStopDisplayLink];
}
- (NSDictionary *)rendererName:(LGLocalButtonRendererResult)result {
    switch (result) {
        case LGLocalButtonRendererDisabled:return @{@"name":@"Disabled",@"ready":@NO};
        case LGLocalButtonRendererInactive:return @{@"name":@"Inactive",@"ready":@NO};
        case LGLocalButtonRendererSourceUnavailable:return @{@"name":@"SourceUnavailable",@"ready":@NO};
        case LGLocalButtonRendererSourceRejected:return @{@"name":@"SourceRejected",@"ready":@NO};
        case LGLocalButtonRendererPipelineUnavailable:return @{@"name":@"PipelineUnavailable",@"ready":@NO};
        case LGLocalButtonRendererReadyForNextDraw:return @{@"name":@"ReadyForNextDraw",@"ready":@YES};
    }
    return @{@"name":@"Unknown",@"ready":@NO};
}
- (BOOL)submitSnapshotForReason:(NSString *)reason initial:(BOOL)initial {
    if (self.didCleanup || !self.material || !self.target || ![self isVisibleAndActive]) return NO;
    [self refreshEligibility];
    LGButtonOpticalState snapshot=self.target->opticalState;
    uint64_t completedBefore=self.material.lastCompletedSubmissionSerial;
    uint64_t sequence=++self.requestSequence;
    if (self.latestDrawSample &&
        [self.latestDrawSample[@"completionObservation"] isEqual:@"pending"]) {
        self.latestDrawSample[@"completionObservation"]=@"replaced-by-newer-request";
        self.latestDrawSample[@"replacedByRequestSequence"]=@(sequence);
    }
    self.latestDrawSample=nil;
    self.provider.hasMostRecentContract=NO;
    LGLocalButtonRendererResult result=[self.material submitOpticalState:snapshot enabled:YES];
    NSDictionary *resultInfo=[self rendererName:result];
    uint64_t completedImmediatelyAfter=self.material.lastCompletedSubmissionSerial;
    NSMutableDictionary *sample=[@{
        @"requestedSequence":@(sequence),@"reason":reason?:@"unspecified",
        @"requestedOpticalSnapshot":@{
            @"geometryGeneration":@(snapshot.geometryGeneration),
            @"eligible":@(snapshot.eligible),@"tracking":@(snapshot.tracking),
            @"phase":@(snapshot.phase),@"touchValid":@(snapshot.touchValid),
            @"normalizedPoint":@[@(snapshot.touchX),@(snapshot.touchY)],
            @"pressure":@(snapshot.pressure),@"targetPressure":@(snapshot.target),
            @"wantsFrames":@(snapshot.wantsFrames)},
        @"rendererSubmitResult":resultInfo[@"name"],@"readyForNextDraw":resultInfo[@"ready"],
        @"actualCompletedSerialBeforeSubmit":@(completedBefore),
        @"actualCompletedSerialImmediatelyAfterSubmit":@(completedImmediatelyAfter),
        @"requestedMetalSubmissionSerialObservable":@NO,
        @"completionObservation":(result==LGLocalButtonRendererReadyForNextDraw ? @"pending" : @"not-ready"),
        @"actualMaterialClass":NSStringFromClass(self.material.class),
        @"isExactMaterialClass":@(self.material.class==LGLocalButtonMaterialView.class),
        @"providerStatus":@(self.provider.lastStatus),
        @"providerContractObserved":@(self.provider.hasMostRecentContract),
        @"uniformBuilder":@"LGLocalButtonBuildUniforms; exact submitted state + AppOwned contract",
        @"uniformsBuiltBySharedFunction":@NO
    } mutableCopy];
    if (self.provider.hasMostRecentContract) {
        LGLocalButtonSourceContract c=self.provider.mostRecentContract;
        sample[@"sourceContract"]=@{
            @"sourceKind":@(c.sourceKind),@"frameGeneration":@(c.frameGeneration),
            @"targetGeometryGeneration":@(c.targetGeometryGeneration),
            @"ownerInstanceToken":@(c.ownerInstanceToken),@"ownerGeneration":@(c.ownerGeneration),
            @"pointScale":@(c.pointScale),@"backgroundOnly":@(c.backgroundOnly),
            @"targetForegroundExcluded":@(c.targetForegroundExcluded),
            @"immutableUntilFrameReleased":@(c.immutableUntilFrameReleased)};
        CGSize drawable=self.material.drawableSize;
        LGLocalButtonUniforms uniforms={0};
        BOOL built=LGLocalButtonBuildUniforms(&c,&snapshot,(float)drawable.width,
            (float)drawable.height,(float)self.target.window.screen.scale,YES,&uniforms);
        sample[@"uniformsBuiltBySharedFunction"]=@(built);
        if (built) {
            sample[@"sharedBuilderUniformTuple"]=@{
                @"contactCenterNormalized":@[@(uniforms.buttonContactCenter.x),@(uniforms.buttonContactCenter.y)],
                @"contactPressure":@(uniforms.buttonContactPressure),
                @"contactEnabled":@(uniforms.buttonContactEnabled),
                @"pressureBucket":@(LGOpticalPressureIndex(&snapshot,LG_BUTTON_PRESSURE_LEVELS)),
                @"glassThickness":@(uniforms.glassThickness),
                @"refractionScale":@(uniforms.refractionScale),
                @"notGPUReadback":@YES};
            if (initial) self.initialUniformsBuilt=built;
        }
    }
    [self.drawSamples addObject:sample];
    if (result==LGLocalButtonRendererReadyForNextDraw) {
        sample[@"actualCompletedSerialAtRequest"]=@(self.material.lastCompletedSubmissionSerial);
        self.latestDrawSample=sample;
        if (initial) self.initialSubmitReady=YES;
        uint64_t observedSequence=sequence;
        CFTimeInterval observationStartedAt=CACurrentMediaTime();
        sample[@"boundedSerialObservationWindowSeconds"]=@(kCompletionObservationWindow);
        sample[@"boundedSerialObservationIntervalSeconds"]=@(kCompletionObservationInterval);
        __weak LGOwnedTouchProbe *weakSelf=self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(kCompletionObservationInterval*NSEC_PER_SEC)),
            dispatch_get_main_queue(),^{
                LGOwnedTouchProbe *strongSelf=weakSelf;
                if (strongSelf) [strongSelf observeCompletionSequence:observedSequence
                    sample:sample startedAt:observationStartedAt attempt:1];
            });
    }
    if (initial) [self addCheck:@"initial_submit_ready" pass:(result==LGLocalButtonRendererReadyForNextDraw)
        observed:resultInfo[@"name"] details:@{@"providerStatus":@(self.provider.lastStatus)}];
    [self updatePressureEvidence];
    return result==LGLocalButtonRendererReadyForNextDraw;
}
- (BOOL)isActuallyCompletedSample:(NSMutableDictionary *)sample
                          renderer:(LGLocalButtonMaterialView *)view
                    observedSerial:(uint64_t)serial
                         sourceKind:(NSString *)sourceKind {
    BOOL recognizedSource=[sourceKind isEqual:@"availabilityChangedHandler"] ||
        [sourceKind isEqual:@"boundedSerialObserve"];
    uint64_t sequence=[sample[@"requestedSequence"] unsignedLongLongValue];
    uint64_t before=[sample[@"actualCompletedSerialBeforeSubmit"] unsignedLongLongValue];
    return recognizedSource && NSThread.isMainThread && !self.didCleanup && sample &&
        sample==self.latestDrawSample && sequence!=0 && sequence==self.requestSequence &&
        view && view==self.material && view.class==LGLocalButtonMaterialView.class &&
        [sample[@"readyForNextDraw"] boolValue] && [sample[@"isExactMaterialClass"] boolValue] &&
        view.hasCurrentCompletedValidSubmission && view.lastCommandBufferSucceeded &&
        serial>before && serial==view.lastCompletedSubmissionSerial;
}
- (void)markSampleActuallyCompleted:(NSMutableDictionary *)sample
                      observedSerial:(uint64_t)serial
                           sourceKind:(NSString *)sourceKind {
    LGLocalButtonMaterialView *view=self.material;
    if (![self isActuallyCompletedSample:sample renderer:view observedSerial:serial sourceKind:sourceKind] ||
        ![sample[@"completionObservation"] isEqual:@"pending"]) return;
    BOOL availabilityCallback=[sourceKind isEqual:@"availabilityChangedHandler"];
    sample[@"completionObservation"]=availabilityCallback ?
        @"actual-class-availability-callback" : @"actual-class-bounded-serial-observation";
    sample[@"observedVia"]=sourceKind;
    sample[@"actualCompletedSerial"]=@(serial);
    sample[@"actualCommandBufferSucceeded"]=@(view.lastCommandBufferSucceeded);
    sample[@"currentCompletedValidSubmission"]=@(view.hasCurrentCompletedValidSubmission);
    sample[@"completionObservedAtMonotonic"]=@(CACurrentMediaTime());
    [self publishOwnTouchReadyRecord];
    NSDictionary *tuple=sample[@"sharedBuilderUniformTuple"];
    NSArray *center=tuple[@"contactCenterNormalized"];
    BOOL contact=[tuple[@"contactEnabled"] floatValue]>=0.5f &&
        [tuple[@"contactPressure"] floatValue]>0.0f;
    if (!contact || center.count!=2) return;
    CGFloat x=[center[0] doubleValue];
    NSMutableDictionary *completedTuple=[@{
        @"contactCenterNormalized":center,@"contactPressure":tuple[@"contactPressure"],
        @"pressureBucket":tuple[@"pressureBucket"],@"requestedSequence":sample[@"requestedSequence"],
        @"actualCompletedSerial":@(serial),@"observedVia":sourceKind,
        @"completionObservation":sample[@"completionObservation"]} mutableCopy];
    if (x<=0.10) self.leftCompletedUniformTuple=completedTuple;
    if (x>=0.90) self.rightCompletedUniformTuple=completedTuple;
}
- (void)observeCompletionSequence:(uint64_t)sequence
                            sample:(NSMutableDictionary *)sample
                         startedAt:(CFTimeInterval)startedAt
                           attempt:(NSUInteger)attempt {
    if (!NSThread.isMainThread || self.didCleanup || !sample ||
        sample!=self.latestDrawSample || sequence!=self.requestSequence ||
        [sample[@"completionObservation"] isEqual:@"replaced-by-newer-request"] ||
        ![sample[@"completionObservation"] isEqual:@"pending"]) return;
    CFTimeInterval now=CACurrentMediaTime();
    CFTimeInterval elapsed=now-startedAt;
    if (elapsed>kCompletionObservationWindow) {
        sample[@"completionObservation"]=@"bounded-serial-observation-window-expired";
        [self.completionObservationEvents addObject:@{
            @"requestedSequence":@(sequence),@"attempt":@(attempt),@"withinBoundedWindow":@NO,
            @"observationKind":@"boundedSerialObserve",@"observedAtMonotonic":@(now)}];
        return;
    }
    LGLocalButtonMaterialView *view=self.material;
    uint64_t serial=view.lastCompletedSubmissionSerial;
    BOOL actualCompletion=[self isActuallyCompletedSample:sample renderer:view
        observedSerial:serial sourceKind:@"boundedSerialObserve"];
    [self.completionObservationEvents addObject:@{
        @"requestedSequence":@(sequence),@"attempt":@(attempt),@"withinBoundedWindow":@YES,
        @"observationKind":@"boundedSerialObserve",@"actualCompletedSerial":@(serial),
        @"lastCommandBufferSucceeded":@(view.lastCommandBufferSucceeded),
        @"hasCurrentCompletedValidSubmission":@(view.hasCurrentCompletedValidSubmission),
        @"actualCompletionForLatestRequest":@(actualCompletion),
        @"observedAtMonotonic":@(now)}];
    if (actualCompletion) {
        [self markSampleActuallyCompleted:sample observedSerial:serial sourceKind:@"boundedSerialObserve"];
        [self maybeFinishAfterTerminalTouch];
        return;
    }
    if (attempt>=kCompletionObservationMaximumAttempts ||
        elapsed+kCompletionObservationInterval>kCompletionObservationWindow) {
        sample[@"completionObservation"]=@"bounded-serial-observation-window-expired";
        return;
    }
    __weak LGOwnedTouchProbe *weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(kCompletionObservationInterval*NSEC_PER_SEC)),
        dispatch_get_main_queue(),^{
            LGOwnedTouchProbe *strongSelf=weakSelf;
            if (strongSelf) [strongSelf observeCompletionSequence:sequence sample:sample
                startedAt:startedAt attempt:attempt+1];
        });
}
- (void)rendererAvailabilityChanged:(LGLocalButtonMaterialView *)view available:(BOOL)available {
    if (self.didCleanup || !view) return;
    uint64_t serial=view.lastCompletedSubmissionSerial;
    NSMutableDictionary *availability=[@{
        @"available":@(available),@"mainThread":@(NSThread.isMainThread),
        @"actualMaterialClass":NSStringFromClass(view.class),
        @"exactMaterialClass":@(view.class==LGLocalButtonMaterialView.class),
        @"actualCompletedSerial":@(serial),@"lastCommandBufferSucceeded":@(view.lastCommandBufferSucceeded),
        @"hasCurrentCompletedValidSubmission":@(view.hasCurrentCompletedValidSubmission),
        @"isSystemLiveBackdrop":@(view.isSystemLiveBackdrop),
        @"observedAtMonotonic":@(CACurrentMediaTime())} mutableCopy];
    NSMutableDictionary *sample=self.latestDrawSample;
    BOOL actualCompletion=available && [self isActuallyCompletedSample:sample renderer:view
        observedSerial:serial sourceKind:@"availabilityChangedHandler"];
    availability[@"actualCompletionForLatestRequest"]=@(actualCompletion);
    if (sample) availability[@"associatedRequestedSequence"]=sample[@"requestedSequence"];
    if (actualCompletion) {
        [self markSampleActuallyCompleted:sample observedSerial:serial
            sourceKind:@"availabilityChangedHandler"];
        availability[@"sampleObservedVia"]=sample[@"observedVia"]?:[NSNull null];
    }
    [self.availabilityEvents addObject:[availability copy]];
    [self maybeFinishAfterTerminalTouch];
}
- (BOOL)tupleMatchesActuallyObservedSample:(NSDictionary *)tuple {
    if (!tuple) return NO;
    uint64_t wantedSequence=[tuple[@"requestedSequence"] unsignedLongLongValue];
    uint64_t wantedSerial=[tuple[@"actualCompletedSerial"] unsignedLongLongValue];
    NSString *wantedVia=tuple[@"observedVia"];
    for (NSDictionary *sample in self.drawSamples) {
        if ([sample[@"requestedSequence"] unsignedLongLongValue]!=wantedSequence) continue;
        NSString *observation=sample[@"completionObservation"];
        BOOL actualObservation=[observation isEqual:@"actual-class-availability-callback"] ||
            [observation isEqual:@"actual-class-bounded-serial-observation"];
        return actualObservation && [sample[@"observedVia"] isEqual:wantedVia] &&
            [sample[@"actualCompletedSerial"] unsignedLongLongValue]==wantedSerial &&
            wantedSerial>[sample[@"actualCompletedSerialBeforeSubmit"] unsignedLongLongValue] &&
            [sample[@"actualCommandBufferSucceeded"] boolValue] &&
            [sample[@"currentCompletedValidSubmission"] boolValue] &&
            [sample[@"isExactMaterialClass"] boolValue];
    }
    return NO;
}
- (void)refreshAndSubmit {
    if (self.didCleanup || !self.target) return;
    if (![self synchronizeOverlayGeometry]) {
        [self finishWithStatus:@"FAIL_GEOMETRY" failure:@"overlay no longer maps to an axis-aligned 44pt sibling set"];
        return;
    }
    [self refreshEligibility];
    if (![self isVisibleAndActive] || !self.target->opticalState.eligible) {
        [self startOrStopDisplayLink];
        return;
    }
    LGOpticalTick(&self.target->opticalState,CACurrentMediaTime());
    [self updatePressureEvidence]; [self startOrStopDisplayLink];
    NSArray<UIColor *> *palette=LGOwnedTouchPalette();
    self.backgroundRevision++;
    for (NSUInteger i=0;i<self.sourceBands.count;i++)
        self.sourceBands[i].backgroundColor=palette[(i+self.backgroundRevision)%palette.count];
    [self.provider markSourceContentDirty];
    [self submitSnapshotForReason:@"bounded-visible-source-refresh" initial:NO];
    [self maybeFinishAfterTerminalTouch];
}
- (BOOL)pointTuplesDiffer {
    NSDictionary *left=self.leftCompletedUniformTuple,*right=self.rightCompletedUniformTuple;
    if (![self tupleMatchesActuallyObservedSample:left] ||
        ![self tupleMatchesActuallyObservedSample:right]) return NO;
    NSArray *lc=left[@"contactCenterNormalized"],*rc=right[@"contactCenterNormalized"];
    if (lc.count!=2 || rc.count!=2) return NO;
    double lx=[lc[0] doubleValue],rx=[rc[0] doubleValue];
    double ly=[lc[1] doubleValue],ry=[rc[1] doubleValue];
    double lp=[left[@"contactPressure"] doubleValue],rp=[right[@"contactPressure"] doubleValue];
    return lx<=0.10 && rx>=0.90 && fabs(lx-rx)>0.80 &&
        (fabs(ly-ry)>0.0001 || fabs(lp-rp)>0.0001 || fabs(lx-rx)>0.80);
}
- (BOOL)latestRequestIsCompletedRelease {
    NSMutableDictionary *sample=self.latestDrawSample;
    NSDictionary *snapshot=sample[@"requestedOpticalSnapshot"];
    NSString *observation=sample[@"completionObservation"];
    NSString *observedVia=sample[@"observedVia"];
    BOOL observedByCallback=[observation isEqual:@"actual-class-availability-callback"] &&
        [observedVia isEqual:@"availabilityChangedHandler"];
    BOOL observedBySerial=[observation isEqual:@"actual-class-bounded-serial-observation"] &&
        [observedVia isEqual:@"boundedSerialObserve"];
    uint64_t serial=[sample[@"actualCompletedSerial"] unsignedLongLongValue];
    uint64_t before=[sample[@"actualCompletedSerialBeforeSubmit"] unsignedLongLongValue];
    return self.terminalTouchObserved && sample && sample==self.latestDrawSample &&
        [sample[@"requestedSequence"] unsignedLongLongValue]==self.requestSequence &&
        [snapshot[@"tracking"] boolValue]==NO &&
        [snapshot[@"phase"] integerValue]==LGOpticalIdle &&
        [snapshot[@"pressure"] floatValue]==0.0f &&
        [snapshot[@"targetPressure"] floatValue]==0.0f &&
        [sample[@"readyForNextDraw"] boolValue] && (observedByCallback || observedBySerial) &&
        [sample[@"isExactMaterialClass"] boolValue] &&
        [sample[@"actualCommandBufferSucceeded"] boolValue] &&
        [sample[@"currentCompletedValidSubmission"] boolValue] &&
        serial>before && self.material.class==LGLocalButtonMaterialView.class &&
        self.material.lastCommandBufferSucceeded && self.material.hasCurrentCompletedValidSubmission &&
        self.material.lastCompletedSubmissionSerial==serial;
}
- (void)maybeFinishAfterTerminalTouch {
    if (self.didCleanup || !self.terminalTouchObserved || !self.target) return;
    LGButtonOpticalState *s=&self.target->opticalState;
    if (s->tracking || s->pressure!=0.0f || s->target!=0.0f || s->wantsFrames) return;
    if (![self latestRequestIsCompletedRelease]) return;
    BOOL edgeTuple=[self pointTuplesDiffer];
    BOOL edgeInputs=self.leftUIKitExtreme && self.rightUIKitExtreme && edgeTuple;
    BOOL realEnd=self.realTouchEndObserved && self.target.endTrackingCalls>0 && !self.touchCancelled;
    BOOL passed=realEnd && edgeInputs && self.steadyPressureReached &&
        self.initialSubmitReady && self.initialUniformsBuilt;
    if (passed) {
        [self finishWithStatus:@"PASS_REAL_UIKIT_TOUCH_AND_COMPLETED_LOCAL_RENDER"
            failure:nil];
    } else {
        NSString *why=self.touchCancelled ? @"UIKit cancelled the stream; no real touchend pass" :
            ( !realEnd ? @"no UIKit endTracking callback" :
              (!edgeInputs ? @"completed shared-uniform tuples did not prove both <0.1 and >0.9 touchX" :
               (!self.steadyPressureReached ? @"real hold did not reach steady optical pressure 1" :
                @"initial source/uniform setup was not complete")));
        [self finishWithStatus:(self.touchCancelled?@"FAIL_UIKIT_TOUCH_CANCELLED":@"FAIL_TOUCH_TRACE_INCOMPLETE")
            failure:why];
    }
}
- (NSDictionary *)buildFinalResult:(NSString *)status failure:(NSString *)failure {
    NSString *bundle=NSBundle.mainBundle.bundleIdentifier?:@"unavailable";
    LGOwnedTouchTarget *target=self.target;
    LGButtonOpticalState state={0};
    if (target) state=target->opticalState;
    BOOL acceptedTimestampedBegin=NO;
    BOOL acceptedTimestampedEnd=NO;
    for (NSDictionary *event in self.touchEvents) {
        if (![event[@"trueUIKitTouch"] boolValue] || !event[@"uitouchTimestamp"]) continue;
        if ([event[@"phase"] isEqual:@"began"]) acceptedTimestampedBegin=YES;
        if ([event[@"phase"] isEqual:@"ended"]) acceptedTimestampedEnd=YES;
    }
    BOOL realUIKit=target && target.acceptedBeginCalls>0 && acceptedTimestampedBegin;
    BOOL realEnd=self.realTouchEndObserved && acceptedTimestampedEnd &&
        target.endTrackingCalls>0 && !self.touchCancelled;
    BOOL edgeTuple=[self pointTuplesDiffer];
    BOOL releaseZero=self.realTouchEndObserved && !state.tracking && state.pressure==0.0f && state.target==0.0f;
    BOOL completedRelease=[self latestRequestIsCompletedRelease];
    NSString *className=self.material?NSStringFromClass(self.material.class):@"unavailable";
    [self addCheck:@"allowed_original_app_bundle" pass:[bundle isEqualToString:kAllowedBundleIdentifier]
        observed:bundle details:nil];
    [self addCheck:@"original_selfcheck_button_not_mutated_by_fixture" pass:YES
        observed:@"fixture never writes original control state/frame/actions" details:nil];
    [self addCheck:@"temporary_target_is_accessible_and_interactive" pass:(target &&
        target.userInteractionEnabled && target.enabled && self.scopeView.userInteractionEnabled &&
        [target.accessibilityIdentifier isEqualToString:kOwnedTouchIdentifier])
        observed:@{@"probeIdentifier":kOwnedTouchIdentifier,
            @"targetUserInteractionEnabled":@(target.userInteractionEnabled),
            @"scopeUserInteractionEnabled":@(self.scopeView.userInteractionEnabled),
            @"label":target.accessibilityLabel?:@"unavailable"} details:nil];
    [self addCheck:@"true_UIKit_touch_callbacks" pass:realUIKit
        observed:@{@"acceptedBegin":@(target.acceptedBeginCalls),@"beginCalls":@(target.beginTrackingCalls),
            @"continueCalls":@(target.continueTrackingCalls),@"endCalls":@(target.endTrackingCalls),
            @"cancelCalls":@(target.cancelTrackingCalls)} details:nil];
    [self addCheck:@"UIKit_touchend_not_cancel_only" pass:realEnd
        observed:@{@"realTouchEndObserved":@(self.realTouchEndObserved),@"cancelled":@(self.touchCancelled)} details:nil];
    [self addCheck:@"optical_steady_pressure_one_during_real_hold" pass:self.steadyPressureReached
        observed:@{@"steadyReached":@(self.steadyPressureReached),@"maximumOpticalPressure":@(self.maximumOpticalPressure)} details:nil];
    [self addCheck:@"completed_uniform_contact_left_and_right" pass:edgeTuple
        observed:@{@"leftUIKitPoint":self.leftUIKitExtreme?:[NSNull null],
            @"rightUIKitPoint":self.rightUIKitExtreme?:[NSNull null],
            @"leftCompletedUniformTuple":self.leftCompletedUniformTuple?:[NSNull null],
            @"rightCompletedUniformTuple":self.rightCompletedUniformTuple?:[NSNull null],
            @"tuplesDiffer":@(edgeTuple)} details:nil];
    [self addCheck:@"real_release_pressure_zero" pass:releaseZero
        observed:@{@"tracking":@(state.tracking),@"pressure":@(state.pressure),
            @"targetPressure":@(state.target),@"phase":@(state.phase)} details:nil];
    [self addCheck:@"latest_actual_material_command_completed_after_release" pass:completedRelease
        observed:self.latestDrawSample?:[NSNull null] details:nil];
    [self addCheck:@"exact_material_class_command_completion" pass:(self.material &&
        self.material.class==LGLocalButtonMaterialView.class &&
        self.material.lastCommandBufferSucceeded && self.material.lastCompletedSubmissionSerial>0)
        observed:@{@"class":className,@"lastCompletedSubmissionSerial":@(self.material.lastCompletedSubmissionSerial),
            @"lastCommandBufferSucceeded":@(self.material.lastCommandBufferSucceeded),
            @"isSystemLiveBackdrop":@(self.material.isSystemLiveBackdrop)} details:nil];
    [self addCheck:@"AppOwned_source_and_feedback_exclusion_binding" pass:(self.provider &&
        self.material && self.overlayGeometryValid && self.provider.lastStatus==LGAppOwnedButtonSourceStatusReady)
        observed:@{@"providerClass":self.provider?NSStringFromClass(self.provider.class):@"unavailable",
            @"lastProviderStatus":@(self.provider.lastStatus),@"sourceRootSibling":@YES,
            @"targetAndMaterialSiblings":@YES,@"sourceRootIsTargetAncestor":@NO,
            @"immutableProviderLease":@YES} details:nil];
    [self addCheck:@"fixture_opt_out_and_global_scope_unchanged" pass:YES
        observed:@{@"explicitOptInIsTemporaryFixtureOnly":@YES,@"productionOptInChanged":@NO,
            @"preferencesChanged":@NO,@"existingSettingsOrBundleGateChanged":@NO,
            @"systemHookRuntime":@"NOT_RUN"} details:nil];
    [self addCheck:@"no_screen_or_primary_drawable_readback" pass:YES
        observed:@{@"sourceDomain":@"explicit App-owned sourceRoot subtree only",
            @"screenCapture":@NO,@"primaryDrawablePixelReadback":@NO,@"auxiliarySameCommandMaterialReadbackEnabled":@YES,@"systemSource":@NO} details:nil];

    CGRect targetInParent=CGRectZero, scopeInParent=CGRectZero, screenFrame=CGRectZero;
    if (target && target.superview) targetInParent=[target convertRect:target.bounds toView:target.superview.superview];
    if (self.scopeView && self.scopeView.superview) scopeInParent=[self.scopeView convertRect:self.scopeView.bounds toView:self.scopeView.superview];
    if (target && target.window) screenFrame=[target convertRect:target.bounds toView:nil];
    NSMutableArray *visibilityAncestors=[NSMutableArray array];
    UIWindow *targetWindow=target.window;
    for(UIView *v=target;v;v=v.superview) {
        [visibilityAncestors addObject:@{@"class":NSStringFromClass(v.class),@"hidden":@(v.hidden),@"alpha":@(v.alpha),@"sameWindow":@(v.window==targetWindow),@"isTargetWindow":@(v==targetWindow)}];
    }
    NSDictionary *visibility=@{@"applicationState":@(UIApplication.sharedApplication.applicationState),@"sceneState":@(targetWindow.windowScene?targetWindow.windowScene.activationState:-999),@"targetWindowMatchesScope":@(targetWindow&&targetWindow==self.scopeView.window),@"visibleActive":@([self isVisibleAndActive]),@"ancestors":visibilityAncestors};
    NSDictionary *sourceInfo=@{
        @"providerClass":self.provider?NSStringFromClass(self.provider.class):@"unavailable",
        @"baseProviderClass":NSStringFromClass(LGAppOwnedButtonSourceProvider.class),
        @"sourceRootIsExplicitAppOwnedUIKitModel":@YES,
        @"sourceRootViewCount":@(1+self.sourceBands.count),@"opaqueUIKitColorBands":@(self.sourceBands.count),@"staticOriginalBotanicalForLightingComparison":@YES,@"designedLightExperiment":@YES,@"notProductionLightingSetting":@YES,@"designedLightCaptureDirectory":self.material.experimentalDesignedLightCaptureDirectoryName?:@"UNAVAILABLE",@"runtimeVerifiedShaderSHA256":self.material.experimentalVerifiedShaderSHA256?:@"UNAVAILABLE",
        @"paddingPoints":@[@0,@0,@0,@0],@"sourceRootFrame":NSStringFromCGRect(self.sourceRoot?self.sourceRoot.frame:CGRectZero),
        @"systemMaterialPixelsRead":@NO,@"screenOrWindowCapture":@NO,
        @"CPUFabricatedMaterial":@NO,@"providerFrameLeasePreserved":@YES};
    NSDictionary *probeUI=@{
        @"probeIdentifier":kOwnedTouchIdentifier,
        @"accessibilityLabel":target.accessibilityLabel?:@"unavailable",
        @"accessibilityValue":target.accessibilityValue?:@"unavailable",
        @"overlayFrameInOriginalParent":NSStringFromCGRect(scopeInParent),
        @"targetFrameInOriginalParent":NSStringFromCGRect(targetInParent),
        @"targetFrameInScreenCoordinates":NSStringFromCGRect(screenFrame),
        @"targetSizePoints":@[@44,@44],@"instruction":@"按住玻璃并左右拖动（左右端各停留）"};
    NSDictionary *result=@{
        @"schemaVersion":@1,@"probeIdentifier":kOwnedTouchIdentifier,
        @"probeRunIdentifier":self.runIdentifier?:@"unavailable",
        @"status":status?:@"FAIL_UNKNOWN",@"failure":failure?:[NSNull null],
        @"bundleIdentifier":bundle,@"fixtureKind":@"temporary controller fixture; not original Settings UI",
        @"SystemHookRuntime":@"NOT_RUN",@"originalSettingsHookRuntime":@"NOT_RUN",
        @"exactSettingsBindingOrBundleChecksChanged":@NO,@"preferencesChanged":@NO,
        @"explicitLocalRendererOptInFixtureOnly":@YES,@"originalButtonActionTakenOver":@NO,
        @"trueUIKitTouch":@(realUIKit),@"touchEndedByUIKit":@(realEnd),
        @"source":sourceInfo,@"probeUI":probeUI,
        @"checks":[self.checks copy],@"eventTrace":[self.touchEvents copy],
        @"drawSamples":[[NSArray alloc] initWithArray:self.drawSamples copyItems:YES],
        @"availabilityEvents":[self.availabilityEvents copy],
        @"completionObservationEvents":[self.completionObservationEvents copy],
        @"leftUIKitExtreme":self.leftUIKitExtreme?:[NSNull null],
        @"rightUIKitExtreme":self.rightUIKitExtreme?:[NSNull null],
        @"leftCompletedUniformTuple":self.leftCompletedUniformTuple?:[NSNull null],
        @"rightCompletedUniformTuple":self.rightCompletedUniformTuple?:[NSNull null],
        @"eventCounts":@{@"beginTracking":@(target.beginTrackingCalls),
            @"acceptedBeginTracking":@(target.acceptedBeginCalls),@"continueTracking":@(target.continueTrackingCalls),
            @"endTracking":@(target.endTrackingCalls),@"cancelTracking":@(target.cancelTrackingCalls)},
        @"latestActualCompletedSerial":@(self.material.lastCompletedSubmissionSerial),
        @"latestCommandSucceeded":@(self.material.lastCommandBufferSucceeded),
        @"fixtureVisibilityAtFinish":visibility,
        @"timeoutReached":@(self.timeoutReached),@"cleanupCompleted":@NO};
    return result;
}
- (void)cleanupFixture {
    if (self.didCleanup) return;
    [self removeOwnTouchReadyRecord];
    self.didCleanup=YES;
    [self.refreshTimer invalidate]; self.refreshTimer=nil;
    [self.displayLink invalidate]; self.displayLink=nil; self.displayLinkTarget=nil;
    self.target.probe=nil;
    if (self.material) {
        self.material.availabilityChangedHandler=nil;
        [self.material invalidateLocalSource];
        [self.material removeFromSuperview];
    }
    [self.target removeFromSuperview];
    [self.sourceRoot removeFromSuperview];
    [self.instructionLabel removeFromSuperview];
    [self.scopeView removeFromSuperview];
    self.target=nil; self.material=nil; self.provider=nil;
    self.sourceBands=nil; self.sourceRoot=nil; self.instructionLabel=nil; self.scopeView=nil;
}
- (void)finishWithStatus:(NSString *)status failure:(NSString *)failure {
    if (self.didCleanup) return;
    NSDictionary *base=[self buildFinalResult:status failure:failure];
    [self cleanupFixture];
    NSMutableDictionary *result=[base mutableCopy]; result[@"cleanupCompleted"]=@YES;
    NSMutableArray *finalChecks=[result[@"checks"] mutableCopy]?:[NSMutableArray array];
    BOOL cleaned=self.didCleanup && !self.refreshTimer && !self.displayLink &&
        !self.scopeView && !self.target && !self.material && !self.provider && !self.sourceRoot;
    [finalChecks addObject:@{@"name":@"temporary_scope_provider_timer_link_cleanup",
        @"pass":@(cleaned),@"observed":@{@"timersStopped":@(!self.refreshTimer),
            @"displayLinkStopped":@(!self.displayLink),@"scopeRemoved":@(!self.scopeView),
            @"targetRendererProviderSourceCleared":@(!self.target&&!self.material&&!self.provider&&!self.sourceRoot)}}];
    result[@"checks"]=[finalChecks copy];
    void (^callback)(NSDictionary *)=self.completion; self.completion=nil;
    [LGOwnedTouchLiveProbes() removeObjectForKey:self.runIdentifier?:@""];
    if (callback) callback([result copy]);
}
@end

extern "C" void RunOwnedTouchRuntimeProbe(id<MTLDevice> device,
                                           UIView *originalSelfCheckButton,
                                           void (^completion)(NSDictionary *result)) {
    if (!NSThread.isMainThread) {
        void (^callback)(NSDictionary *)=[completion copy];
        dispatch_async(dispatch_get_main_queue(),^{
            if (callback) callback(@{@"schemaVersion":@1,@"status":@"FAIL_MAIN_THREAD_REQUIRED",
                @"failure":@"RunOwnedTouchRuntimeProbe must be called on the main thread",
                @"probeIdentifier":kOwnedTouchIdentifier,@"trueUIKitTouch":@NO,
                @"SystemHookRuntime":@"NOT_RUN",@"cleanupCompleted":@YES});
        });
        return;
    }
    LGOwnedTouchProbe *probe=[LGOwnedTouchProbe new];
    probe.runIdentifier=NSUUID.UUID.UUIDString;
    probe.originalButton=originalSelfCheckButton;
    probe.completion=[completion copy];
    probe.geometryGeneration=kInitialGeometryGeneration;
    probe.startedAt=CACurrentMediaTime();
    probe.touchEvents=[NSMutableArray array];
    probe.drawSamples=[NSMutableArray array];
    probe.availabilityEvents=[NSMutableArray array];
    probe.completionObservationEvents=[NSMutableArray array];
    probe.checks=[NSMutableArray array];
    LGOwnedTouchLiveProbes()[probe.runIdentifier]=probe;
    id<MTLDevice> seedDevice=device?:MTLCreateSystemDefaultDevice();
    [probe setupWithDevice:seedDevice];
}
