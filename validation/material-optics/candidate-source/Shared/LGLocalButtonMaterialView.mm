#import "LGLocalButtonMaterialView.h"
#import "LGLocalButtonUniforms.h"
#import "LGButtonMaterialCandidate.h"
#import "LGLocalButtonShaderSource.h"
#import "LGLocalButtonRefreshPolicy.h"
#import <CommonCrypto/CommonDigest.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>
#import <math.h>
#import <string.h>

static const char kExpectedLocalShaderSHA256[] =
    "a0910f9e9450ead5dbc265493fd67256efccbd75111cc6c61e9890eef508b727";

@interface LGLocalButtonMaterialView ()
@property(nonatomic,weak) UIView *targetView;
@property(nonatomic,strong) id<LGLocalButtonSourceProvider> sourceProvider;
@property(nonatomic,strong) LGLocalButtonTextureFrame *sourceFrame;
/* A second strong lease exists only for the last GPU-completed frame. It keeps
 * old material available during refresh and is dropped at completion/reject/expiry. */
@property(nonatomic,strong) LGLocalButtonTextureFrame *completedFrame;
@property(nonatomic,assign) LGButtonOpticalState completedStateSnapshot;
@property(nonatomic,assign) BOOL hasCompletedStateSnapshot;
@property(nonatomic,assign) uint64_t completedOwnerToken;
@property(nonatomic,assign) uint64_t completedOwnerGeneration;
@property(nonatomic,assign) uint64_t completedMinimumFrameGeneration;
@property(nonatomic,assign) uint64_t completedSubmissionSerial;
// Do not retain a texture/frame just to remember identity after clear: doing
// so would delay provider lease return. A zeroing weak reference prevents
// address-reuse false matches once the original texture was destroyed.
@property(nonatomic,weak) id<MTLTexture> lastAcceptedTexture;
@property(nonatomic,assign) LGLocalButtonSourceContract lastAcceptedContract;
@property(nonatomic,assign) BOOL hasLastAcceptedFrameIdentity;
@property(nonatomic,strong) id<MTLRenderPipelineState> localPipeline;
@property(nonatomic,strong) id<MTLCommandQueue> localCommandQueue;
@property(nonatomic,strong) id<MTLSamplerState> localSampler;
@property(nonatomic,strong) dispatch_semaphore_t localInFlight;
@property(nonatomic,assign) LGButtonOpticalState stateSnapshot;
@property(nonatomic,assign) BOOL hasStateSnapshot;
@property(nonatomic,assign) CGFloat requestedHostAlpha;
@property(nonatomic,assign) BOOL contentSuppressionActive;
@property(nonatomic,assign) BOOL alphaIntentInitialized;
- (void)setCompletedContentVisible:(BOOL)visible;
@property(nonatomic,assign) BOOL explicitOptIn;
@property(nonatomic,assign) BOOL allowApproximateSource;
@property(nonatomic,assign) uint64_t boundOwnerToken;
@property(nonatomic,assign) uint64_t boundOwnerGeneration;
@property(nonatomic,assign) uint64_t minimumFrameGeneration;
@property(nonatomic,assign) LGLocalSourceKind activeSourceKind;
@property(nonatomic,assign) LGLocalSourceCursor sourceCursor;
@property(nonatomic,assign) uint64_t submissionSerial;
@property(nonatomic,assign) uint64_t lastCompletedSubmissionSerial;
@property(nonatomic,assign) BOOL lastCommandBufferSucceeded;
@property(nonatomic,assign) BOOL pendingDraw;
@property(nonatomic,assign) BOOL drawRequestScheduled;
- (void)requestLocalDraw;
@property(nonatomic,assign) BOOL availabilityPublished;
@property(nonatomic,strong) NSTimer *sourceExpiryTimer;
@property(nonatomic,assign) uint64_t sourceExpiryGuardGeneration;
@property(nonatomic,strong) id resignObserver;
- (BOOL)prepareLocalPipeline;
- (BOOL)targetCanRender;
- (void)clearLocalFrame;
- (void)publishAvailability:(BOOL)available;
- (BOOL)currentCompletedFrameIsAvailable;
- (BOOL)retainedCompletedFrameIsAvailableAt:(CFTimeInterval)now;
- (BOOL)displayableCompletedMaterialIsAvailable;
- (BOOL)frameStillValid:(LGLocalButtonTextureFrame *)frame now:(CFTimeInterval)now;
- (BOOL)frameStillValid:(LGLocalButtonTextureFrame *)frame
                  state:(LGButtonOpticalState)state
             ownerToken:(uint64_t)ownerToken
       ownerGeneration:(uint64_t)ownerGeneration
minimumFrameGeneration:(uint64_t)minimumFrameGeneration
                    now:(CFTimeInterval)now;
- (void)armSourceExpiryGuard;
- (void)sourceExpiryGuardFired:(uint64_t)guardGeneration;
- (void)discardRetainedCompletedFrame;
- (void)abandonCurrentSubmissionPreservingValidCompletion;
@end

@interface LGLocalButtonTextureFrame ()
@property(nonatomic,copy) dispatch_block_t leaseEnded;
@end

@implementation LGLocalButtonTextureFrame
- (instancetype)initWithTexture:(id<MTLTexture>)texture
                       contract:(LGLocalButtonSourceContract)contract {
    return [self initWithTexture:texture contract:contract leaseEnded:nil];
}
- (instancetype)initWithTexture:(id<MTLTexture>)texture
                       contract:(LGLocalButtonSourceContract)contract
                     leaseEnded:(dispatch_block_t)leaseEnded {
    if (!texture || !contract.immutableUntilFrameReleased) return nil;
    if ((self=[super init])) {
        _texture=texture; _contract=contract; _leaseEnded=[leaseEnded copy];
    }
    return self;
}
- (void)dealloc { if (_leaseEnded) _leaseEnded(); }
@end

@implementation LGLocalButtonMaterialView
- (instancetype)initWithFrame:(CGRect)frame targetView:(UIView *)targetView
                sourceProvider:(id<LGLocalButtonSourceProvider>)provider
         allowApproximateSource:(BOOL)allowApproximateSource
                 explicitOptIn:(BOOL)explicitOptIn {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    if (!device || !targetView || !provider) return nil;
    if ((self=[super initWithFrame:frame device:device])) {
        _targetView=targetView; _sourceProvider=provider;
        _allowApproximateSource=allowApproximateSource;
        _explicitOptIn=(LG_LOCAL_BUTTON_RENDERER_COMPILED!=0) && explicitOptIn;
        _localInFlight=dispatch_semaphore_create(3);
        self.delegate=self; self.paused=YES; self.enableSetNeedsDisplay=YES;
        self.framebufferOnly=YES; self.colorPixelFormat=MTLPixelFormatBGRA8Unorm_sRGB;
        self.clearColor=MTLClearColorMake(0,0,0,0); self.opaque=NO;
        self.backgroundColor=UIColor.clearColor; self.userInteractionEnabled=NO;
        _requestedHostAlpha=[super alpha]; _alphaIntentInitialized=YES;
        self.hidden=YES; [self setCompletedContentVisible:NO];
        self.accessibilityElementsHidden=YES;
        self.layer.cornerRadius=LG_LOCAL_BUTTON_VIEW_POINTS * 0.5;
        self.layer.cornerCurve=kCACornerCurveContinuous;
        self.layer.masksToBounds=YES;
        if (_explicitOptIn) {
            [self prepareLocalPipeline];
            __weak LGLocalButtonMaterialView *weakSelf=self;
            _resignObserver=[NSNotificationCenter.defaultCenter
                addObserverForName:UIApplicationWillResignActiveNotification
                object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) {
                    [weakSelf invalidateLocalSource];
                }];
        }
    }
    return self;
}
- (void)dealloc {
    [_sourceExpiryTimer invalidate];
    if (_resignObserver) [NSNotificationCenter.defaultCenter removeObserver:_resignObserver];
}

- (void)setCompletedContentVisible:(BOOL)visible {
    self.contentSuppressionActive=!visible;
    self.layer.opacity=visible?(float)self.requestedHostAlpha:0.0f;
}
- (void)setAlpha:(CGFloat)alpha {
    _requestedHostAlpha=alpha;
    [super setAlpha:alpha];
    if (!_alphaIntentInitialized) return;
    if (_contentSuppressionActive) self.layer.opacity=0.0f;
    if (!isfinite(alpha) || alpha<0.01) [self clearLocalFrame];
}
- (void)setAvailabilityChangedHandler:(LGLocalButtonAvailabilityHandler)handler {
    _availabilityChangedHandler=[handler copy];
    if (!handler) { self.availabilityPublished=NO; return; }
    BOOL available=[self displayableCompletedMaterialIsAvailable];
    self.availabilityPublished=available;
    handler(self,available);
}

- (BOOL)currentCompletedFrameIsAvailable {
    CFTimeInterval now=CACurrentMediaTime();
    return !self.hidden && self.layer.opacity>0.0f && !self.pendingDraw &&
        self.sourceFrame && self.sourceFrame==self.completedFrame &&
        self.lastCommandBufferSucceeded &&
        self.lastCompletedSubmissionSerial==self.submissionSerial &&
        self.completedSubmissionSerial==self.submissionSerial &&
        [self frameStillValid:self.sourceFrame now:now];
}

- (BOOL)retainedCompletedFrameIsAvailableAt:(CFTimeInterval)now {
    LGLocalButtonTextureFrame *frame=self.completedFrame;
    if (!frame || !self.hasCompletedStateSnapshot || self.hidden ||
        self.layer.opacity<=0.0f || !self.stateSnapshot.eligible ||
        self.completedSubmissionSerial!=self.lastCompletedSubmissionSerial ||
        self.completedStateSnapshot.geometryGeneration!=self.stateSnapshot.geometryGeneration)
        return NO;
    LGLocalButtonSourceContract c=frame.contract;
    BOOL sameOwner=!self.sourceFrame ||
        (self.sourceFrame.contract.ownerInstanceToken==c.ownerInstanceToken &&
         self.sourceFrame.contract.ownerGeneration==c.ownerGeneration);
    BOOL sameGeometry=!self.sourceFrame ||
        self.sourceFrame.contract.targetGeometryGeneration==c.targetGeometryGeneration;
    BOOL alive=[self.sourceProvider isOwnerInstanceAlive:c.ownerInstanceToken
                                              generation:c.ownerGeneration];
    BOOL eligible=self.explicitOptIn && self.hasStateSnapshot &&
        self.stateSnapshot.eligible && [self targetCanRender];
    if (!LGLocalRetainedCompletionFresh(now,c.frameTimestampMonotonic,sameOwner,
                                        sameGeometry,alive,eligible)) return NO;
    return [self frameStillValid:frame state:self.completedStateSnapshot
                      ownerToken:self.completedOwnerToken
                ownerGeneration:self.completedOwnerGeneration
           minimumFrameGeneration:self.completedMinimumFrameGeneration now:now];
}

- (BOOL)displayableCompletedMaterialIsAvailable {
    BOOL current=[self currentCompletedFrameIsAvailable];
    BOOL retained=[self retainedCompletedFrameIsAvailableAt:CACurrentMediaTime()];
    return LGLocalStableCompletedAvailability(current,retained);
}

- (void)publishAvailability:(BOOL)available {
    if (![NSThread isMainThread]) {
        __weak LGLocalButtonMaterialView *weakSelf=self;
        dispatch_async(dispatch_get_main_queue(), ^{
            LGLocalButtonMaterialView *strongSelf=weakSelf;
            if (strongSelf) [strongSelf publishAvailability:
                [strongSelf displayableCompletedMaterialIsAvailable]];
        });
        return;
    }
    if (available && ![self displayableCompletedMaterialIsAvailable]) available=NO;
    if (self.availabilityPublished==available) return;
    self.availabilityPublished=available;
    LGLocalButtonAvailabilityHandler handler=self.availabilityChangedHandler;
    if (handler) handler(self,available);
}

- (BOOL)prepareLocalPipeline {
    if (!self.device) return NO;
    self.localCommandQueue=[self.device newCommandQueue];
    if (!self.localCommandQueue) return NO;
    NSData *sourceData=[NSData dataWithBytes:kLGLocalButtonCandidateMSL
                                     length:strlen(kLGLocalButtonCandidateMSL)];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(sourceData.bytes,(CC_LONG)sourceData.length,digest);
    static const char hex[]="0123456789abcdef"; char actual[65];
    for (NSUInteger i=0;i<sizeof(digest);i++) {
        actual[i*2]=hex[digest[i]>>4]; actual[i*2+1]=hex[digest[i]&15];
    }
    actual[64]=0;
    if (strcmp(actual,kExpectedLocalShaderSHA256)!=0 ||
        strcmp(kLGLocalButtonCandidateMSLSHA256,kExpectedLocalShaderSHA256)!=0)
        return NO;
    NSString *source=[[NSString alloc] initWithData:sourceData
                                           encoding:NSUTF8StringEncoding];
    if (!source) return NO;
    NSError *error=nil;
    id<MTLLibrary> library=[self.device newLibraryWithSource:source options:nil error:&error];
    if (!library) return NO;
    id<MTLFunction> vertex=[library newFunctionWithName:@"liquidGlassVertex"];
    id<MTLFunction> fragment=[library newFunctionWithName:@"liquidGlassFragment"];
    if (!vertex || !fragment) return NO;
    MTLRenderPipelineDescriptor *descriptor=[MTLRenderPipelineDescriptor new];
    descriptor.label=@"LiquidAss same-process local button material";
    descriptor.vertexFunction=vertex; descriptor.fragmentFunction=fragment;
    descriptor.colorAttachments[0].pixelFormat=self.colorPixelFormat;
    MTLRenderPipelineColorAttachmentDescriptor *color=descriptor.colorAttachments[0];
    color.blendingEnabled=YES;
    color.rgbBlendOperation=MTLBlendOperationAdd;
    color.alphaBlendOperation=MTLBlendOperationAdd;
    // Full shader returns premultiplied sampled color. SourceAlpha here would
    // multiply alpha twice and darken translucent edges.
    color.sourceRGBBlendFactor=MTLBlendFactorOne;
    color.destinationRGBBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
    color.sourceAlphaBlendFactor=MTLBlendFactorOne;
    color.destinationAlphaBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
    error=nil;
    self.localPipeline=[self.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!self.localPipeline) return NO;
    MTLSamplerDescriptor *sd=[MTLSamplerDescriptor new];
    sd.minFilter=MTLSamplerMinMagFilterLinear; sd.magFilter=MTLSamplerMinMagFilterLinear;
    sd.sAddressMode=MTLSamplerAddressModeClampToEdge;
    sd.tAddressMode=MTLSamplerAddressModeClampToEdge;
    self.localSampler=[self.device newSamplerStateWithDescriptor:sd];
    return self.localSampler!=nil;
}

- (void)clearLocalFrame {
    [self.sourceExpiryTimer invalidate]; self.sourceExpiryTimer=nil;
    if (self.sourceExpiryGuardGeneration<UINT64_MAX) self.sourceExpiryGuardGeneration++;
    if (self.submissionSerial<UINT64_MAX) self.submissionSerial++;
    self.sourceFrame=nil; self.completedFrame=nil;
    self.hasCompletedStateSnapshot=NO;
    self.completedOwnerToken=0; self.completedOwnerGeneration=0;
    self.completedMinimumFrameGeneration=0; self.completedSubmissionSerial=0;
    self.activeSourceKind=LGLocalSourceNone;
    self.hidden=YES; [self setCompletedContentVisible:NO]; self.pendingDraw=NO;
    self.hasStateSnapshot=NO; self.lastCommandBufferSucceeded=NO;
    [self publishAvailability:NO];
}
- (BOOL)targetCanRender {
    UIView *target=self.targetView;
    if (!target || !target.window || self.window!=target.window ||
        !self.superview || target.superview!=self.superview ||
        !isfinite(self.requestedHostAlpha) || self.requestedHostAlpha<0.01 ||
        UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)
        return NO;
    if (target.window.windowScene && target.window.windowScene.activationState!=UISceneActivationStateForegroundActive)
        return NO;
    if ([target isKindOfClass:UIControl.class] && !((UIControl *)target).enabled)
        return NO;
    for (UIView *v=target; v; v=v.superview)
        if (v.hidden || v.alpha<0.01) return NO;
    for (UIView *v=self.superview; v; v=v.superview)
        if (v.hidden || v.alpha<0.01) return NO;
    return YES;
}
- (void)discardRetainedCompletedFrame {
    self.completedFrame=nil;
    self.hasCompletedStateSnapshot=NO;
    self.completedOwnerToken=0; self.completedOwnerGeneration=0;
    self.completedMinimumFrameGeneration=0; self.completedSubmissionSerial=0;
    self.lastCommandBufferSucceeded=NO;
    // Keep a still-fresh candidate drawable alive for an in-flight refresh, but
    // never expose stale MTKView contents over the restored stock glass.
    [self setCompletedContentVisible:NO];
    [self publishAvailability:[self displayableCompletedMaterialIsAvailable]];
}

- (void)abandonCurrentSubmissionPreservingValidCompletion {
    if (![self retainedCompletedFrameIsAvailableAt:CACurrentMediaTime()]) {
        [self clearLocalFrame]; return;
    }
    if (self.submissionSerial==UINT64_MAX) { [self clearLocalFrame]; return; }
    self.submissionSerial++;
    self.sourceFrame=nil; self.activeSourceKind=LGLocalSourceNone;
    self.pendingDraw=NO; self.lastCommandBufferSucceeded=NO;
    [self setCompletedContentVisible:YES];
    [self armSourceExpiryGuard];
    [self publishAvailability:YES];
}

- (void)armSourceExpiryGuard {
    [self.sourceExpiryTimer invalidate]; self.sourceExpiryTimer=nil;
    if (self.sourceExpiryGuardGeneration==UINT64_MAX) {
        [self clearLocalFrame]; return;
    }
    const uint64_t guard=++self.sourceExpiryGuardGeneration;
    CFTimeInterval now=CACurrentMediaTime();
    CFTimeInterval delay=INFINITY;
    if (self.sourceFrame) {
        LGLocalButtonSourceContract c=self.sourceFrame.contract;
        delay=MIN(delay,LGLocalSourceExpiryDelay(&c,now));
    }
    if (self.completedFrame) {
        LGLocalButtonSourceContract c=self.completedFrame.contract;
        delay=MIN(delay,LGLocalSourceExpiryDelay(&c,now));
    }
    if (!isfinite(delay)) return;
    __weak LGLocalButtonMaterialView *weakSelf=self;
    self.sourceExpiryTimer=[NSTimer timerWithTimeInterval:fmax(delay,0.0001)
        repeats:NO block:^(__unused NSTimer *timer) {
            LGLocalButtonMaterialView *strongSelf=weakSelf;
            if (strongSelf) [strongSelf sourceExpiryGuardFired:guard];
        }];
    [NSRunLoop.mainRunLoop addTimer:self.sourceExpiryTimer forMode:NSRunLoopCommonModes];
}

- (void)sourceExpiryGuardFired:(uint64_t)guardGeneration {
    if (![NSThread isMainThread]) {
        __weak LGLocalButtonMaterialView *weakSelf=self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf sourceExpiryGuardFired:guardGeneration];
        });
        return;
    }
    if (guardGeneration!=self.sourceExpiryGuardGeneration) return;
    self.sourceExpiryTimer=nil;
    CFTimeInterval now=CACurrentMediaTime();
    if (self.sourceFrame && ![self frameStillValid:self.sourceFrame now:now]) {
        [self clearLocalFrame]; return;
    }
    if (self.completedFrame && ![self retainedCompletedFrameIsAvailableAt:now])
        [self discardRetainedCompletedFrame];
    if (!self.sourceFrame && !self.completedFrame) {
        [self clearLocalFrame]; return;
    }
    [self armSourceExpiryGuard];
}
- (void)invalidateLocalSource {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self invalidateLocalSource]; });
        return;
    }
    [self clearLocalFrame]; self.hasStateSnapshot=NO;
}

- (LGLocalButtonRendererResult)submitOpticalState:(LGButtonOpticalState)state
                                          enabled:(BOOL)enabled {
    if (![NSThread isMainThread]) return LGLocalButtonRendererInactive;
    const uint64_t serialBeforeStateCallback=self.submissionSerial;
    self.stateSnapshot=state; self.hasStateSnapshot=YES;
    CFTimeInterval now=CACurrentMediaTime();
    if (self.completedFrame && ![self retainedCompletedFrameIsAvailableAt:now])
        [self discardRetainedCompletedFrame];
    else
        [self publishAvailability:[self displayableCompletedMaterialIsAvailable]];
    // Availability callbacks can synchronously clear/unbind this exact view.
    if (self.submissionSerial!=serialBeforeStateCallback || !self.hasStateSnapshot)
        return LGLocalButtonRendererInactive;
    if (!LG_LOCAL_BUTTON_RENDERER_COMPILED || !self.explicitOptIn || !enabled) {
        [self clearLocalFrame]; return LGLocalButtonRendererDisabled;
    }
    UIView *target=self.targetView;
    if (!state.eligible || ![self targetCanRender] ||
        !self.localPipeline || !self.localSampler || !self.localCommandQueue) {
        [self clearLocalFrame];
        if (!self.localPipeline || !self.localSampler || !self.localCommandQueue)
            return LGLocalButtonRendererPipelineUnavailable;
        return LGLocalButtonRendererInactive;
    }
    if (fabs(CGRectGetWidth(target.bounds)-LG_LOCAL_BUTTON_VIEW_POINTS)>0.01 ||
        fabs(CGRectGetHeight(target.bounds)-LG_LOCAL_BUTTON_VIEW_POINTS)>0.01 ||
        fabs(CGRectGetWidth(self.bounds)-LG_LOCAL_BUTTON_VIEW_POINTS)>0.01 ||
        fabs(CGRectGetHeight(self.bounds)-LG_LOCAL_BUTTON_VIEW_POINTS)>0.01 ||
        !self.superview || target.superview!=self.superview) {
        [self clearLocalFrame]; return LGLocalButtonRendererSourceRejected;
    }
    CGRect targetFrame=[target convertRect:target.bounds toView:self.superview];
    if (!LGLocalRectSame(targetFrame,self.frame)) {
        [self clearLocalFrame]; return LGLocalButtonRendererSourceRejected;
    }
    LGLocalButtonTextureFrame *frame=[self.sourceProvider
        currentBackgroundFrameForTargetView:target monotonicTimestamp:now];
    if (!frame || !frame.texture) {
        [self clearLocalFrame]; return LGLocalButtonRendererSourceUnavailable;
    }
    LGLocalButtonSourceContract c=frame.contract;
    uint64_t expectedOwner=self.boundOwnerToken ? self.boundOwnerToken : c.ownerInstanceToken;
    BOOL ownerAlive=[self.sourceProvider isOwnerInstanceAlive:c.ownerInstanceToken
                                                   generation:c.ownerGeneration];
    uint64_t expectedOwnerGeneration=self.boundOwnerGeneration ?
        self.boundOwnerGeneration : c.ownerGeneration;
    uint64_t minimumGeneration=self.minimumFrameGeneration;
    if (self.boundOwnerToken && c.ownerInstanceToken==self.boundOwnerToken &&
        c.ownerGeneration>self.boundOwnerGeneration && ownerAlive) {
        expectedOwnerGeneration=c.ownerGeneration;
        minimumGeneration=0;
    }
    LGLocalSourceValidation v=LGLocalValidateSourceContract(&c,now,
        expectedOwner,expectedOwnerGeneration,minimumGeneration,
        state.geometryGeneration,(uint32_t)frame.texture.width,
        (uint32_t)frame.texture.height,(uint32_t)frame.texture.pixelFormat,
        (uint32_t)self.colorPixelFormat,ownerAlive,self.allowApproximateSource);
    if (v!=LGLocalSourceValid || !LGLocalRectSame(c.targetRectInOwnerPoints,targetFrame) ||
        frame.texture.width>LG_LOCAL_BUTTON_MAX_TEXTURE_DIMENSION ||
        frame.texture.height>LG_LOCAL_BUTTON_MAX_TEXTURE_DIMENSION ||
        frame.texture.device!=self.device || frame.texture.sampleCount!=1 ||
        frame.texture.textureType!=MTLTextureType2D ||
        !(frame.texture.usage&MTLTextureUsageShaderRead)) {
        [self clearLocalFrame]; return LGLocalButtonRendererSourceRejected;
    }
    LGLocalSourceCursor cursor=self.sourceCursor;
    if (!LGLocalSourceAcceptOrder(&cursor,&c)) {
        [self clearLocalFrame]; return LGLocalButtonRendererSourceRejected;
    }
    LGLocalButtonSourceContract previousContract=self.lastAcceptedContract;
    id<MTLTexture> previousTexture=self.lastAcceptedTexture;
    BOOL sameTexture=previousTexture && previousTexture==frame.texture;
    if (!LGLocalRepeatedFrameIdentityValid(&c,&previousContract,
            self.hasLastAcceptedFrameIdentity,sameTexture)) {
        [self clearLocalFrame]; return LGLocalButtonRendererSourceRejected;
    }
    self.sourceCursor=cursor;
    self.lastAcceptedTexture=frame.texture;
    self.lastAcceptedContract=c;
    self.hasLastAcceptedFrameIdentity=YES;
    self.boundOwnerToken=c.ownerInstanceToken;
    self.boundOwnerGeneration=c.ownerGeneration;
    self.minimumFrameGeneration=c.frameGeneration;
    self.sourceFrame=frame; self.activeSourceKind=c.sourceKind;
    if (self.submissionSerial==UINT64_MAX) {
        [self clearLocalFrame]; return LGLocalButtonRendererInactive;
    }
    self.lastCommandBufferSucceeded=NO;
    BOOL retainedFresh=[self retainedCompletedFrameIsAvailableAt:CACurrentMediaTime()];
    if (!retainedFresh && self.completedFrame) [self discardRetainedCompletedFrame];
    else if (!retainedFresh) [self setCompletedContentVisible:NO];
    const uint64_t serialBeforeAvailabilityCallback=self.submissionSerial;
    [self publishAvailability:[self displayableCompletedMaterialIsAvailable]];
    // This check deliberately precedes pendingDraw/visibility/serial mutation:
    // a synchronous callback invalidation cannot revive a cleared submission.
    if (self.submissionSerial!=serialBeforeAvailabilityCallback ||
        self.sourceFrame!=frame || !self.hasStateSnapshot)
        return LGLocalButtonRendererInactive;
    self.submissionSerial++;
    self.pendingDraw=YES;
    uint32_t targetPixelWidth=0,targetPixelHeight=0;
    if (!LGLocalSourceTargetPixelSize(&c,&targetPixelWidth,&targetPixelHeight)) {
        [self clearLocalFrame]; return LGLocalButtonRendererSourceRejected;
    }
    self.contentScaleFactor=c.pointScale;
    self.drawableSize=CGSizeMake(targetPixelWidth,targetPixelHeight);
    self.hidden=NO;
    BOOL allowed=LGLocalButtonMayRender(LG_LOCAL_BUTTON_RENDERER_COMPILED!=0,
        self.explicitOptIn,state.eligible,self.window==target.window,true,
        self.localPipeline!=nil&&self.localSampler!=nil&&self.localCommandQueue!=nil);
    if (!allowed) { [self clearLocalFrame]; return LGLocalButtonRendererInactive; }
    [self armSourceExpiryGuard];
    [self requestLocalDraw];
    return LGLocalButtonRendererReadyForNextDraw;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) [self clearLocalFrame];
}

- (BOOL)frameStillValid:(LGLocalButtonTextureFrame *)frame now:(CFTimeInterval)now {
    return [self frameStillValid:frame state:self.stateSnapshot
                      ownerToken:self.boundOwnerToken
                ownerGeneration:self.boundOwnerGeneration
           minimumFrameGeneration:self.minimumFrameGeneration now:now];
}

- (BOOL)frameStillValid:(LGLocalButtonTextureFrame *)frame
                  state:(LGButtonOpticalState)state
             ownerToken:(uint64_t)ownerToken
       ownerGeneration:(uint64_t)ownerGeneration
minimumFrameGeneration:(uint64_t)minimumFrameGeneration
                    now:(CFTimeInterval)now {
    UIView *target=self.targetView;
    if (!frame || !target || !state.eligible || !self.explicitOptIn ||
        ![self targetCanRender] || !self.superview || target.superview!=self.superview ||
        fabs(CGRectGetWidth(target.bounds)-LG_LOCAL_BUTTON_VIEW_POINTS)>0.01 ||
        fabs(CGRectGetHeight(target.bounds)-LG_LOCAL_BUTTON_VIEW_POINTS)>0.01 ||
        fabs(CGRectGetWidth(self.bounds)-LG_LOCAL_BUTTON_VIEW_POINTS)>0.01 ||
        fabs(CGRectGetHeight(self.bounds)-LG_LOCAL_BUTTON_VIEW_POINTS)>0.01)
        return NO;
    CGRect targetFrame=[target convertRect:target.bounds toView:self.superview];
    LGLocalButtonSourceContract c=frame.contract;
    if (!LGLocalRectSame(targetFrame,self.frame) ||
        !LGLocalRectSame(c.targetRectInOwnerPoints,targetFrame) ||
        frame.texture.width>LG_LOCAL_BUTTON_MAX_TEXTURE_DIMENSION ||
        frame.texture.height>LG_LOCAL_BUTTON_MAX_TEXTURE_DIMENSION ||
        frame.texture.device!=self.device || frame.texture.sampleCount!=1 ||
        frame.texture.textureType!=MTLTextureType2D ||
        !(frame.texture.usage&MTLTextureUsageShaderRead)) return NO;
    BOOL alive=[self.sourceProvider isOwnerInstanceAlive:c.ownerInstanceToken
                                              generation:c.ownerGeneration];
    return LGLocalValidateSourceContract(&c,now,ownerToken,ownerGeneration,
        minimumFrameGeneration,state.geometryGeneration,
        (uint32_t)frame.texture.width,(uint32_t)frame.texture.height,
        (uint32_t)frame.texture.pixelFormat,(uint32_t)self.colorPixelFormat,
        alive,self.allowApproximateSource)==LGLocalSourceValid;
}

- (BOOL)isApproximateSource {
    return LGLocalSourceIsApproximate(self.activeSourceKind);
}
- (BOOL)isSystemLiveBackdrop { return NO; }
- (BOOL)hasCurrentCompletedValidSubmission {
    return [self currentCompletedFrameIsAvailable];
}
- (BOOL)hasDisplayableCompletedMaterial {
    if (!NSThread.isMainThread) return NO;
    return [self displayableCompletedMaterialIsAvailable];
}
- (BOOL)hasCurrentValidSourceFrame {
    return !self.hidden && self.sourceFrame && self.hasStateSnapshot &&
        [self frameStillValid:self.sourceFrame now:CACurrentMediaTime()];
}

- (BOOL)buildUniformsForFrame:(LGLocalButtonTextureFrame *)frame
                 drawableSize:(CGSize)drawableSize
                        state:(LGButtonOpticalState)state
                       output:(LGLocalButtonUniforms *)out {
    if (!frame || !out || !state.eligible) return NO;
    LGLocalButtonSourceContract c=frame.contract;
    float rendererScale=(float)self.targetView.window.screen.scale;
    return LGLocalButtonBuildUniforms(&c,&state,
        (float)drawableSize.width,(float)drawableSize.height,rendererScale,
        self.explicitOptIn,out);
}

- (void)requestLocalDraw {
    if (!NSThread.isMainThread || self.drawRequestScheduled || !self.pendingDraw) return;
    self.drawRequestScheduled=YES;
    [self setNeedsDisplay];
    __weak LGLocalButtonMaterialView *weakSelf=self;
    dispatch_async(dispatch_get_main_queue(), ^{
        LGLocalButtonMaterialView *strongSelf=weakSelf;
        if (!strongSelf) return;
        strongSelf.drawRequestScheduled=NO;
        if (strongSelf.pendingDraw && strongSelf.sourceFrame && !strongSelf.hidden)
            [strongSelf draw];
    });
}
- (void)drawInMTKView:(MTKView *)view {
    if (!NSThread.isMainThread) return;
    LGLocalButtonTextureFrame *frame=self.sourceFrame;
    if (!self.pendingDraw) return;
    if (!self.explicitOptIn || !self.localPipeline || !self.localSampler ||
        ![self frameStillValid:frame now:CACurrentMediaTime()]) {
        [self clearLocalFrame]; return;
    }
    if (dispatch_semaphore_wait(self.localInFlight,DISPATCH_TIME_NOW)!=0) return;
    id<CAMetalDrawable> drawable=view.currentDrawable;
    MTLRenderPassDescriptor *pass=view.currentRenderPassDescriptor;
    if (!drawable || !pass || drawable.texture.pixelFormat!=self.colorPixelFormat) {
        dispatch_semaphore_signal(self.localInFlight);
        [self abandonCurrentSubmissionPreservingValidCompletion]; return;
    }
    LGButtonOpticalState submittedState=self.stateSnapshot;
    LGLocalButtonUniforms uniforms={};
    if (![self buildUniformsForFrame:frame drawableSize:view.drawableSize
                              state:submittedState output:&uniforms]) {
        dispatch_semaphore_signal(self.localInFlight); [self clearLocalFrame]; return;
    }
    pass.colorAttachments[0].loadAction=MTLLoadActionClear;
    pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
    id<MTLCommandBuffer> command=[self.localCommandQueue commandBuffer];
    if (!command) {
        dispatch_semaphore_signal(self.localInFlight);
        [self abandonCurrentSubmissionPreservingValidCompletion]; return;
    }
    command.label=@"LiquidAss local 44pt source-to-drawable";
    id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        dispatch_semaphore_signal(self.localInFlight);
        [self abandonCurrentSubmissionPreservingValidCompletion]; return;
    }
    [encoder setRenderPipelineState:self.localPipeline];
    [encoder setFragmentTexture:frame.texture atIndex:0];
    [encoder setFragmentTexture:frame.texture atIndex:1]; /* mask disabled in this path */
    [encoder setFragmentSamplerState:self.localSampler atIndex:0];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    const uint64_t serial=self.submissionSerial;
    self.pendingDraw=NO;
    dispatch_semaphore_t inFlight=self.localInFlight;
    LGLocalButtonTextureFrame *retainedFrame=frame;
    __weak LGLocalButtonMaterialView *weakSelf=self;
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        BOOL succeeded=completed.status==MTLCommandBufferStatusCompleted;
        dispatch_semaphore_signal(inFlight);
        // retainedFrame is used in the posted validation and stays alive until
        // completion, even if this view was detached or its source was replaced.
        dispatch_async(dispatch_get_main_queue(), ^{
            LGLocalButtonMaterialView *strongSelf=weakSelf;
            if (!strongSelf) return;
            if (strongSelf.submissionSerial==serial &&
                strongSelf.sourceFrame==retainedFrame) {
                CFTimeInterval now=CACurrentMediaTime();
                if (!succeeded) {
                    [strongSelf clearLocalFrame];
                    return;
                }
                LGLocalButtonSourceContract contract=retainedFrame.contract;
                if (![strongSelf frameStillValid:retainedFrame state:submittedState
                    ownerToken:contract.ownerInstanceToken
                    ownerGeneration:contract.ownerGeneration
                    minimumFrameGeneration:contract.frameGeneration now:now]) {
                    [strongSelf clearLocalFrame]; return;
                }
                strongSelf.completedFrame=retainedFrame;
                strongSelf.completedStateSnapshot=submittedState;
                strongSelf.hasCompletedStateSnapshot=YES;
                strongSelf.completedOwnerToken=contract.ownerInstanceToken;
                strongSelf.completedOwnerGeneration=contract.ownerGeneration;
                strongSelf.completedMinimumFrameGeneration=contract.frameGeneration;
                strongSelf.completedSubmissionSerial=serial;
                strongSelf.lastCommandBufferSucceeded=YES;
                strongSelf.lastCompletedSubmissionSerial=serial;
                [strongSelf setCompletedContentVisible:YES];
                [strongSelf armSourceExpiryGuard];
                [strongSelf publishAvailability:YES];
            }
            if (strongSelf.pendingDraw && strongSelf.sourceFrame)
                [strongSelf requestLocalDraw];
        });
    }];
    [command presentDrawable:drawable];
    [command commit];
}
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    if (!NSThread.isMainThread || !self.sourceFrame) return;
    LGLocalButtonSourceContract c=self.sourceFrame.contract;
    uint32_t targetWidth=0,targetHeight=0;
    if (!LGLocalSourceTargetPixelSize(&c,&targetWidth,&targetHeight) ||
        fabs(size.width-targetWidth)>2 || fabs(size.height-targetHeight)>2)
        [self clearLocalFrame];
}
@end
