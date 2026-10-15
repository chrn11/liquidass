#import "LGLocalButtonMaterialView.h"
#import "LGLocalButtonUniforms.h"
#import "LGButtonMaterialCandidate.h"
#import "LGLocalButtonShaderSource.h"
#import <CommonCrypto/CommonDigest.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>
#import <math.h>
#import <string.h>

static const char kExpectedLocalShaderSHA256[] =
    "f21b394471fd9d3983502441852e3be0664eec7614a7bcd7652939077c06a72b";

@interface LGLocalButtonMaterialView ()
@property(nonatomic,weak) UIView *targetView;
@property(nonatomic,strong) id<LGLocalButtonSourceProvider> sourceProvider;
@property(nonatomic,strong) LGLocalButtonTextureFrame *sourceFrame;
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
@property(nonatomic,strong) NSTimer *sourceExpiryTimer;
@property(nonatomic,strong) id resignObserver;
- (BOOL)prepareLocalPipeline;
- (BOOL)targetCanRender;
- (void)clearLocalFrame;
- (BOOL)frameStillValid:(LGLocalButtonTextureFrame *)frame now:(CFTimeInterval)now;
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
        self.hidden=YES; self.accessibilityElementsHidden=YES;
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
    if (self.submissionSerial<UINT64_MAX) self.submissionSerial++;
    self.sourceFrame=nil; self.activeSourceKind=LGLocalSourceNone;
    self.hidden=YES; self.pendingDraw=NO;
    self.hasStateSnapshot=NO; self.lastCommandBufferSucceeded=NO;
}
- (BOOL)targetCanRender {
    UIView *target=self.targetView;
    if (!target || !target.window || self.window!=target.window ||
        !self.superview || target.superview!=self.superview || self.alpha<0.01 ||
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
- (void)armExpiryForFrame:(LGLocalButtonTextureFrame *)frame {
    [self.sourceExpiryTimer invalidate];
    const uint64_t serial=self.submissionSerial;
    LGLocalButtonSourceContract c=frame.contract;
    NSTimeInterval delay=LGLocalSourceExpiryDelay(&c,CACurrentMediaTime());
    __weak LGLocalButtonMaterialView *weakSelf=self;
    self.sourceExpiryTimer=[NSTimer timerWithTimeInterval:fmax(delay,0.0001)
        repeats:NO block:^(__unused NSTimer *timer) {
            LGLocalButtonMaterialView *strongSelf=weakSelf;
            if (strongSelf && strongSelf.submissionSerial==serial)
                [strongSelf clearLocalFrame];
        }];
    [NSRunLoop.mainRunLoop addTimer:self.sourceExpiryTimer forMode:NSRunLoopCommonModes];
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
    self.stateSnapshot=state; self.hasStateSnapshot=YES;
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
    CFTimeInterval now=CACurrentMediaTime();
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
    self.submissionSerial++;
    self.lastCommandBufferSucceeded=NO;
    self.pendingDraw=YES;
    self.contentScaleFactor=c.pointScale;
    self.drawableSize=CGSizeMake(c.textureWidth,c.textureHeight);
    self.hidden=NO;
    BOOL allowed=LGLocalButtonMayRender(LG_LOCAL_BUTTON_RENDERER_COMPILED!=0,
        self.explicitOptIn,state.eligible,self.window==target.window,true,
        self.localPipeline!=nil&&self.localSampler!=nil&&self.localCommandQueue!=nil);
    if (!allowed) { [self clearLocalFrame]; return LGLocalButtonRendererInactive; }
    [self armExpiryForFrame:frame];
    [self setNeedsDisplay];
    return LGLocalButtonRendererReadyForNextDraw;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) [self clearLocalFrame];
}

- (BOOL)frameStillValid:(LGLocalButtonTextureFrame *)frame now:(CFTimeInterval)now {
    UIView *target=self.targetView;
    if (!frame || !self.hasStateSnapshot || !self.stateSnapshot.eligible ||
        !self.explicitOptIn || ![self targetCanRender] ||
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
    return LGLocalValidateSourceContract(&c,now,self.boundOwnerToken,
        self.boundOwnerGeneration,self.minimumFrameGeneration,
        self.stateSnapshot.geometryGeneration,(uint32_t)frame.texture.width,
        (uint32_t)frame.texture.height,(uint32_t)frame.texture.pixelFormat,
        (uint32_t)self.colorPixelFormat,alive,self.allowApproximateSource)==LGLocalSourceValid;
}

- (BOOL)isApproximateSource {
    return LGLocalSourceIsApproximate(self.activeSourceKind);
}
- (BOOL)isSystemLiveBackdrop { return NO; }

- (BOOL)buildUniformsForFrame:(LGLocalButtonTextureFrame *)frame
                 drawableSize:(CGSize)drawableSize
                        state:(LGButtonOpticalState)state
                       output:(LGLocalButtonUniforms *)out {
    if (!frame || !out || !state.eligible) return NO;
    LGLocalButtonSourceContract c=frame.contract;
    float rendererScale=(float)self.targetView.window.screen.scale;
    return LGLocalButtonBuildUniforms(&c,&state,
        (float)drawableSize.width,(float)drawableSize.height,rendererScale,out);
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
        dispatch_semaphore_signal(self.localInFlight); [self clearLocalFrame]; return;
    }
    LGLocalButtonUniforms uniforms={};
    if (![self buildUniformsForFrame:frame drawableSize:view.drawableSize
                              state:self.stateSnapshot output:&uniforms]) {
        dispatch_semaphore_signal(self.localInFlight); [self clearLocalFrame]; return;
    }
    pass.colorAttachments[0].loadAction=MTLLoadActionClear;
    pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
    id<MTLCommandBuffer> command=[self.localCommandQueue commandBuffer];
    if (!command) { dispatch_semaphore_signal(self.localInFlight); [self clearLocalFrame]; return; }
    command.label=@"LiquidAss local 44pt source-to-drawable";
    id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:pass];
    if (!encoder) { dispatch_semaphore_signal(self.localInFlight); [self clearLocalFrame]; return; }
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
                if (!succeeded || ![strongSelf frameStillValid:retainedFrame now:CACurrentMediaTime()]) {
                    [strongSelf clearLocalFrame];
                    return;
                }
                strongSelf.lastCommandBufferSucceeded=YES;
                strongSelf.lastCompletedSubmissionSerial=serial;
            }
            if (strongSelf.pendingDraw && strongSelf.sourceFrame)
                [strongSelf setNeedsDisplay];
        });
    }];
    [command presentDrawable:drawable];
    [command commit];
}
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    if (!NSThread.isMainThread || !self.sourceFrame) return;
    LGLocalButtonSourceContract c=self.sourceFrame.contract;
    if (fabs(size.width-c.textureWidth)>2 || fabs(size.height-c.textureHeight)>2)
        [self clearLocalFrame];
}
@end
