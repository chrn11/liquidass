#import "LocalRendererRuntimeProbe.h"
#import "LGLocalButtonMaterialView.h"
#import "LGLocalButtonUniforms.h"
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CommonCrypto/CommonDigest.h>
#import <math.h>

@interface LRLeaseCounters : NSObject
@property(nonatomic) NSUInteger active, maximum, ended;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *events;
- (void)opened:(uint64_t)generation;
- (void)closed:(uint64_t)generation;
@end
@implementation LRLeaseCounters
- (instancetype)init { if((self=[super init]))_events=[NSMutableArray array]; return self; }
- (void)opened:(uint64_t)g { @synchronized(self){_active++;_maximum=MAX(_maximum,_active);} }
- (void)closed:(uint64_t)g { @synchronized(self){if(_active)_active--;_ended++;[_events addObject:@{@"generation":@(g),@"endedAtMonotonic":@(CACurrentMediaTime())}];} }
@end

@interface LRStaticAssetProvider : NSObject <LGLocalButtonSourceProvider>
@property(nonatomic,strong) id<MTLTexture> texture;
@property(nonatomic,strong) LRLeaseCounters *leases;
@property(nonatomic) uint64_t ownerToken, geometryGeneration, nextFrameGeneration, forcedGeneration;
@property(nonatomic) BOOL nilFirst, ownerAlive, forceGeneration, repeatExactContract;
@property(nonatomic) LGLocalButtonSourceContract repeatedContract;
@property(nonatomic) CFTimeInterval staleAge;
@property(nonatomic) NSUInteger calls;
@property(nonatomic) LGLocalButtonSourceContract lastContract;
- (instancetype)initWithTexture:(id<MTLTexture>)texture owner:(uint64_t)owner geometry:(uint64_t)geometry;
@end
@implementation LRStaticAssetProvider
- (instancetype)initWithTexture:(id<MTLTexture>)texture owner:(uint64_t)owner geometry:(uint64_t)geometry {
    if((self=[super init])){_texture=texture;_ownerToken=owner;_geometryGeneration=geometry;_ownerAlive=YES;_leases=[LRLeaseCounters new];}return self;
}
- (LGLocalButtonTextureFrame *)currentBackgroundFrameForTargetView:(UIView *)target monotonicTimestamp:(CFTimeInterval)now {
    self.calls++;
    if(self.nilFirst){self.nilFirst=NO;return nil;}
    if(!target || !self.texture)return nil;
    CGRect r=[target convertRect:target.bounds toView:target.superview];
    LGLocalButtonSourceContract c={0}; c.sourceRectInOwnerPoints=r;c.targetRectInOwnerPoints=r;
    c.textureWidth=(uint32_t)self.texture.width;c.textureHeight=(uint32_t)self.texture.height;
    c.pixelFormat=(uint32_t)self.texture.pixelFormat;c.pointScale=3.0f;
    c.ownerInstanceToken=self.ownerToken;c.ownerGeneration=1;
    c.frameGeneration=self.forceGeneration?self.forcedGeneration:++self.nextFrameGeneration;
    c.targetGeometryGeneration=self.geometryGeneration;
    c.frameTimestampMonotonic=now-self.staleAge;c.sourceKind=LGLocalSourceStaticAsset;
    c.alphaMode=LGLocalAlphaOpaque;c.maskKind=LGLocalMaskRounded44;
    c.backgroundOnly=true;c.targetForegroundExcluded=true;c.immutableUntilFrameReleased=true;
    c.sampledRGBIsLinear=true;c.sampledRGBIsPremultiplied=true;
    if(self.repeatExactContract)c=self.repeatedContract;
    self.lastContract=c;
    LRLeaseCounters *counter=self.leases;uint64_t gen=c.frameGeneration;[counter opened:gen];
    return [[LGLocalButtonTextureFrame alloc] initWithTexture:self.texture contract:c leaseEnded:^{[counter closed:gen];}];
}
- (BOOL)isOwnerInstanceAlive:(uint64_t)ownerToken generation:(uint64_t)generation {
    return self.ownerAlive && ownerToken==self.ownerToken && generation==1;
}
@end

@interface LRTestTarget : UIControl @end
@implementation LRTestTarget @end

static NSString *LRResultName(LGLocalButtonRendererResult r) {
    switch(r){case LGLocalButtonRendererDisabled:return @"Disabled";case LGLocalButtonRendererInactive:return @"Inactive";case LGLocalButtonRendererSourceUnavailable:return @"SourceUnavailable";case LGLocalButtonRendererSourceRejected:return @"SourceRejected";case LGLocalButtonRendererPipelineUnavailable:return @"PipelineUnavailable";case LGLocalButtonRendererReadyForNextDraw:return @"ReadyForNextDraw";}return @"Unknown";
}
static LGButtonOpticalState LRState(uint64_t geometry,float pressure) {
    LGButtonOpticalState s;LGOpticalReset(&s,geometry);
    LGOpticalSetEligibility(&s,true,true,true,true,true,geometry);
    s.pressure=pressure; /* synthetic local snapshot; no UIKit touch/touch XY */
    return s;
}
static NSString *LRSHA(NSData *d) {
    if(!d)return @"unavailable";unsigned char h[CC_SHA256_DIGEST_LENGTH];CC_SHA256(d.bytes,(CC_LONG)d.length,h);
    NSMutableString *s=[NSMutableString stringWithCapacity:64];for(NSUInteger i=0;i<sizeof(h);i++)[s appendFormat:@"%02x",h[i]];return s;
}
static LGLocalButtonMaterialView *LRView(UIView *target, LRStaticAssetProvider *provider, BOOL approximate, BOOL optIn) {
    LGLocalButtonMaterialView *v=[[LGLocalButtonMaterialView alloc] initWithFrame:target.frame targetView:target sourceProvider:provider allowApproximateSource:approximate explicitOptIn:optIn];
    if(v)[target.superview insertSubview:v belowSubview:target];return v;
}
/* Main-thread asynchronous test stages. Returning to the outer event loop is
 * essential for CA commits, MTKView's display scheduling and main-queue GPU
 * completion callbacks. Never weaken the production 100ms source lifetime. */
static void LRAwait(CFTimeInterval deadline, BOOL (^predicate)(void), void (^done)(BOOL)) {
    if (predicate()) {done(YES);return;}
    if (CACurrentMediaTime()>=deadline) {done(NO);return;}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        LRAwait(deadline,predicate,done);
    });
}
static void LRDelay(NSTimeInterval duration, dispatch_block_t done) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(duration*NSEC_PER_SEC)),dispatch_get_main_queue(),done);
}
@interface LRAsyncProbe : NSObject
@property(nonatomic,strong) id<MTLDevice> device;
@property(nonatomic,strong) id<MTLCommandQueue> queue;
@property(nonatomic,strong) id<MTLTexture> input,cropA,cropB;
@property(nonatomic,strong) UIView *container;
@property(nonatomic,strong) LRTestTarget *ta,*tb;
@property(nonatomic,strong) LRStaticAssetProvider *pa,*pb;
@property(nonatomic,strong) LGLocalButtonMaterialView *va,*vb;
@property(nonatomic,strong) NSMutableDictionary *report;
@property(nonatomic,strong) NSMutableArray *checks,*draws;
@property(nonatomic,copy) void (^completion)(NSString *,NSString *);
@property(nonatomic) BOOL finished;
@property(nonatomic) uint64_t lastAcceptedA;
@property(nonatomic) LGButtonOpticalState contactReplayA,contactReplayB;
- (void)start;
- (void)setup;
- (void)drawStep:(NSUInteger)step;
- (void)identity;
- (void)guards;
- (void)expiry;
- (void)finish;
@end
@implementation LRAsyncProbe
- (void)record:(NSString *)name pass:(BOOL)pass details:(NSDictionary *)details {
    NSMutableDictionary *r=[@{@"check":name,@"pass":@(pass)} mutableCopy];
    if(details)[r addEntriesFromDictionary:details];[self.checks addObject:r];
}
- (void)start {
    NSCAssert(NSThread.isMainThread,@"Own-App UIKit probe must be main-thread");
    self.checks=[NSMutableArray array];self.draws=[NSMutableArray array];
    self.report=[@{@"schemaVersion":@2,@"runID":NSUUID.UUID.UUIDString,
        @"buildVersion":NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"]?:@"unknown",
        @"bundleID":NSBundle.mainBundle.bundleIdentifier?:@"unknown",
        @"scope":@"Actual frozen LGLocalButtonMaterialView with asynchronous own-App event-loop stages; no system source/UI capture",
        @"mode":@"STATIC_APP_SOURCE_TEST",@"SYSTEM_BACKGROUND_PROVIDER_NOT_IMPLEMENTED":@YES,
        @"pixelEvidence":@"NONE; framebufferOnly remains YES; prior shader pixels are separate evidence",
        @"shaderExpectedSHA256":@"c4dc2e5bcf9080c31a38770637da705d292cbbf7544e43dd30a0d41677541551",
        @"compileMacroLG_LOCAL_BUTTON_RENDERER_COMPILED":@1,
        @"execution":@"ASYNC_STAGED_MAIN_QUEUE; no nested CFRunLoop wait; production source maximum age remains100ms"} mutableCopy];
    if(!self.device||!self.queue||!self.input||!self.container.window||
       self.input.pixelFormat!=MTLPixelFormatBGRA8Unorm_sRGB||self.input.width<132||self.input.height<132) {
        [self record:@"setup_valid_input_window_device" pass:NO details:nil];[self finish];return;
    }
    NSUInteger n=132,x=(self.input.width-n)/2,y=(self.input.height-n)/2;
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB width:n height:n mipmapped:NO];
    td.usage=MTLTextureUsageShaderRead;td.storageMode=MTLStorageModeShared;
    self.cropA=[self.device newTextureWithDescriptor:td];self.cropB=[self.device newTextureWithDescriptor:td];
    id<MTLCommandBuffer> cb=[self.queue commandBuffer];id<MTLBlitCommandEncoder> enc=[cb blitCommandEncoder];
    if(!self.cropA||!self.cropB||!cb||!enc){[self record:@"crop_alloc" pass:NO details:nil];[self finish];return;}
    for(id<MTLTexture> target in @[self.cropA,self.cropB])
        [enc copyFromTexture:self.input sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x,y,0) sourceSize:MTLSizeMake(n,n,1) toTexture:target destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [enc endEncoding];
    self.report[@"source"]=@{@"kind":@"StaticAsset",@"sourceCropPx":@{@"x":@(x),@"y":@(y),@"width":@132,@"height":@132},@"resize":@NO,@"format":@81,@"systemCapture":@NO,@"foregroundIncluded":@NO,@"sourceImmutable":@YES};
    [cb addCompletedHandler:^(id<MTLCommandBuffer> completed){
        BOOL success=completed.status==MTLCommandBufferStatusCompleted;
        dispatch_async(dispatch_get_main_queue(),^{
            [self record:@"own_asset_crop_GPU_completed" pass:success details:nil];
            if(success)[self setup];else[self finish];
        });
    }];[cb commit];
}
- (void)setup {
    self.ta=[LRTestTarget new];self.tb=[LRTestTarget new];
    self.ta.frame=CGRectMake(4,1,44,44);self.tb.frame=CGRectMake(52,1,44,44);
    for(LRTestTarget *t in @[self.ta,self.tb]) {
        t.enabled=YES;t.userInteractionEnabled=NO;t.accessibilityElementsHidden=YES;t.backgroundColor=UIColor.clearColor;
        [self.container addSubview:t];
    }
    [self.container layoutIfNeeded];
    self.pa=[[LRStaticAssetProvider alloc]initWithTexture:self.cropA owner:0xA101 geometry:501];
    self.pb=[[LRStaticAssetProvider alloc]initWithTexture:self.cropB owner:0xB202 geometry:502];
    LGButtonOpticalState state=LRState(501,0);
    LGLocalButtonMaterialView *off=LRView(self.ta,self.pa,YES,NO);
    LGLocalButtonRendererResult result=[off submitOpticalState:state enabled:YES];
    [self record:@"A_explicitOptIn_false" pass:off&&result==LGLocalButtonRendererDisabled&&off.hidden details:@{@"result":LRResultName(result)}];
    [self record:@"A_provider_not_queried_when_opt_out" pass:self.pa.calls==0 details:@{@"calls":@(self.pa.calls)}];[off removeFromSuperview];
    self.pa.nilFirst=YES;self.va=LRView(self.ta,self.pa,YES,YES);
    result=[self.va submitOpticalState:state enabled:YES];
    [self record:@"B_source_provider_returns_nil" pass:self.va&&result==LGLocalButtonRendererSourceUnavailable&&self.va.hidden details:@{@"result":LRResultName(result)}];
    LRStaticAssetProvider *p=[[LRStaticAssetProvider alloc]initWithTexture:self.cropA owner:0xC303 geometry:501];
    LGLocalButtonMaterialView *disallowed=LRView(self.ta,p,NO,YES);result=[disallowed submitOpticalState:state enabled:YES];
    [self record:@"C_static_asset_approximation_disallowed" pass:disallowed&&result==LGLocalButtonRendererSourceRejected&&disallowed.hidden details:@{@"result":LRResultName(result)}];[disallowed removeFromSuperview];
    self.vb=LRView(self.tb,self.pb,YES,YES);
    BOOL actual=self.va&&self.vb&&self.va.framebufferOnly&&self.vb.framebufferOnly;
    [self record:@"D_two_actual_local_class_instances" pass:actual details:@{@"classA":NSStringFromClass(self.va.class)?:@"nil",@"classB":NSStringFromClass(self.vb.class)?:@"nil"}];
    if(!actual){[self finish];return;}
    // Return before any source frame is submitted: let temporary hierarchy and
    // newly created MTKView layers commit in the ordinary main event loop.
    dispatch_async(dispatch_get_main_queue(),^{[self drawStep:0];});
}
- (void)drawStep:(NSUInteger)step {
    if(self.finished)return;
    if(step>=8){[self identity];return;}
    float pressure=step==1?1:0;
    LGButtonOpticalState a=LRState(501,pressure),b=LRState(502,pressure);
    if(step>=3) {
        if(step==3) {
            a=LRState(501,0);b=LRState(502,0);
            LGOpticalBegin(&a,1,true,true,11,22,44,44);
            LGOpticalBegin(&b,1,true,true,33,22,44,44);
            LGOpticalTick(&a,1.10);LGOpticalTick(&b,1.10);
        } else {
            a=self.contactReplayA;b=self.contactReplayB;
            if(step==4) {
                LGOpticalContinue(&a,1.12,true,true,33,28,44,44);
                LGOpticalContinue(&b,1.12,true,true,11,16,44,44);
            } else if(step==5) {
                LGOpticalEnd(&a,1.13,false);LGOpticalEnd(&b,1.13,true);
                LGOpticalTick(&a,1.18);LGOpticalTick(&b,1.18);
            } else if(step==6) {
                LGOpticalTick(&a,3.0);LGOpticalTick(&b,3.0);
            } else {
                LGOpticalReset(&a,501);LGOpticalReset(&b,502);
                LGOpticalSetEligibility(&a,false,true,true,true,true,501);
                LGOpticalSetEligibility(&b,false,true,true,true,true,502);
                // Rendering disabled/ineligible is separately checked by guards.
                // Here re-enable a clean idle state to prove no residual contact.
                LGOpticalSetEligibility(&a,true,true,true,true,true,501);
                LGOpticalSetEligibility(&b,true,true,true,true,true,502);
            }
        }
        self.contactReplayA=a;self.contactReplayB=b;
        pressure=a.pressure;
    }
    uint64_t sa=self.va.lastCompletedSubmissionSerial,sb=self.vb.lastCompletedSubmissionSerial;
    LGLocalButtonRendererResult ra=[self.va submitOpticalState:a enabled:YES],rb=[self.vb submitOpticalState:b enabled:YES];
    BOOL ready=ra==LGLocalButtonRendererReadyForNextDraw&&rb==LGLocalButtonRendererReadyForNextDraw;
    if(ra==LGLocalButtonRendererReadyForNextDraw)self.lastAcceptedA=self.pa.lastContract.frameGeneration;
    LGLocalButtonSourceContract ca=self.pa.lastContract,cb=self.pb.lastContract;
    LGLocalButtonUniforms ua={0},ub={0};BOOL ba=LGLocalButtonBuildUniforms(&ca,&a,132,132,3,true,&ua),bb=LGLocalButtonBuildUniforms(&cb,&b,132,132,3,true,&ub);
    CFTimeInterval started=CACurrentMediaTime();
    LRAwait(started+2.0,^BOOL {
        return !ready || (self.va.lastCompletedSubmissionSerial>sa&&self.va.lastCommandBufferSucceeded&&!self.va.hidden&&
                           self.vb.lastCompletedSubmissionSerial>sb&&self.vb.lastCommandBufferSucceeded&&!self.vb.hidden);
    },^(BOOL observed){
        BOOL done=ready&&observed&&self.va.lastCompletedSubmissionSerial>sa&&self.vb.lastCompletedSubmissionSerial>sb;
        NSDictionary *frame=@{@"state":@(step),@"syntheticPressure":@(pressure),@"UIKitTouchInjected":@NO,
          @"providerAResult":LRResultName(ra),@"providerBResult":LRResultName(rb),
          @"frameGenerationA":@(ca.frameGeneration),@"frameGenerationB":@(cb.frameGeneration),
          @"completedSerialA":@(self.va.lastCompletedSubmissionSerial),@"completedSerialB":@(self.vb.lastCompletedSubmissionSerial),
          @"commandCompleteObservedA":@(done&&self.va.lastCommandBufferSucceeded),@"commandCompleteObservedB":@(done&&self.vb.lastCommandBufferSucceeded),
          @"bucket":@(LGOpticalPressureIndex(&a,9)),@"uniformBuildA":@(ba),@"uniformBuildB":@(bb),
          @"thicknessA":@(ua.glassThickness),@"refractionA":@(ua.refractionScale),
          @"hiddenA":@(self.va.hidden),@"hiddenB":@(self.vb.hidden),
          @"sourceTimestampA":@(ca.frameTimestampMonotonic),@"elapsed":@(CACurrentMediaTime()-started),
          @"systemSource":@NO,@"pixelReadback":@NO};
        [self.draws addObject:frame];
        NSMutableDictionary *contactFrame=[frame mutableCopy];
        contactFrame[@"localUniformABIBytes"]=@(sizeof(LGLocalButtonUniforms));
        contactFrame[@"touchValidA"]=@(a.touchValid);contactFrame[@"touchValidB"]=@(b.touchValid);
        contactFrame[@"contactUniformEnabledA"]=@(ua.buttonContactEnabled>0.5f);
        contactFrame[@"contactUniformEnabledB"]=@(ub.buttonContactEnabled>0.5f);
        contactFrame[@"contactXYA"]=@[@(ua.buttonContactCenter.x),@(ua.buttonContactCenter.y)];
        contactFrame[@"contactXYB"]=@[@(ub.buttonContactCenter.x),@(ub.buttonContactCenter.y)];
        contactFrame[@"contactPressureA"]=@(ua.buttonContactPressure);
        contactFrame[@"statePhaseA"]=@(a.phase);contactFrame[@"statePhaseB"]=@(b.phase);
        BOOL expectedContact=step>=3 && step<=5;
        BOOL correctContact=(ua.buttonContactEnabled>0.5f)==expectedContact &&
                            (ub.buttonContactEnabled>0.5f)==expectedContact;
        if(expectedContact) correctContact=correctContact && a.touchValid && b.touchValid &&
            fabs(ua.buttonContactCenter.x-a.touchX)<.00001 && fabs(ub.buttonContactCenter.x-b.touchX)<.00001 &&
            fabs(ua.buttonContactPressure-a.pressure)<.00001;
        contactFrame[@"contactTupleMatchesExactState"]=@(correctContact);
        [self.draws removeLastObject];[self.draws addObject:contactFrame];
        [self record:[NSString stringWithFormat:@"D_actual_draw_GPU_complete_step%lu",(unsigned long)step]
            pass:done&&ba&&bb&&correctContact details:contactFrame];
        // A completed serial is required, not ReadyForNextDraw or visibility.
        if(done&&correctContact)dispatch_async(dispatch_get_main_queue(),^{[self drawStep:step+1];});
        else [self guards];
    });
}
- (void)identity {
    // Ensure the reference tuple was really accepted and rendered, then clear
    // only the view's active source. Metadata and timestamp are replayed EXACTLY.
    LGButtonOpticalState state=LRState(501,0);
    uint64_t before=self.va.lastCompletedSubmissionSerial;
    LGLocalButtonRendererResult initial=[self.va submitOpticalState:state enabled:YES];
    LGLocalButtonSourceContract accepted=self.pa.lastContract;
    BOOL ready=initial==LGLocalButtonRendererReadyForNextDraw;
    if(ready)self.lastAcceptedA=accepted.frameGeneration;
    LRAwait(CACurrentMediaTime()+2.0,^BOOL {
        return !ready || (self.va.lastCompletedSubmissionSerial>before&&self.va.lastCommandBufferSucceeded&&!self.va.hidden);
    },^(BOOL seen){
        BOOL prerequisite=ready&&seen&&self.va.lastCompletedSubmissionSerial>before;
        [self record:@"H_reuse_reference_actually_GPU_completed" pass:prerequisite details:nil];
        if(!prerequisite){[self guards];return;}
        [self.va invalidateLocalSource];
        self.pa.repeatExactContract=YES;self.pa.repeatedContract=accepted;
        self.pa.texture=self.cropB; // different MTLTexture, SAME pixels and tuple
        CFTimeInterval age=CACurrentMediaTime()-accepted.frameTimestampMonotonic;
        LGLocalButtonRendererResult swap=[self.va submitOpticalState:state enabled:YES];
        [self record:@"H_clear_same_generation_cannot_replace_texture" pass:age<.100&&swap==LGLocalButtonRendererSourceRejected&&self.va.hidden details:@{@"result":LRResultName(swap),@"exactTimestampReplayed":@YES,@"ageSeconds":@(age),@"sameFrameGeneration":@(accepted.frameGeneration),@"differentTextureObject":@YES}];
        self.pa.texture=self.cropA;
        LGLocalButtonSourceContract changed=accepted;
        changed.alphaMode=LGLocalAlphaPremultiplied; // both valid for opaque pixels
        self.pa.repeatedContract=changed;
        age=CACurrentMediaTime()-accepted.frameTimestampMonotonic;
        LGLocalButtonRendererResult descriptor=[self.va submitOpticalState:state enabled:YES];
        [self record:@"H_clear_same_generation_cannot_change_descriptor" pass:age<.100&&descriptor==LGLocalButtonRendererSourceRejected&&self.va.hidden details:@{@"result":LRResultName(descriptor),@"exactTimestampReplayed":@YES,@"ageSeconds":@(age),@"sameTextureObject":@YES}];
        self.pa.repeatedContract=accepted;
        uint64_t prior=self.va.lastCompletedSubmissionSerial;
        age=CACurrentMediaTime()-accepted.frameTimestampMonotonic;
        LGLocalButtonRendererResult same=[self.va submitOpticalState:state enabled:YES];
        BOOL correct=age<.100&&same==LGLocalButtonRendererReadyForNextDraw;
        LRAwait(CACurrentMediaTime()+2.0,^BOOL {
            return !correct || (self.va.lastCompletedSubmissionSerial>prior&&self.va.lastCommandBufferSucceeded&&!self.va.hidden);
        },^(BOOL completed){
            [self record:@"H_clear_same_exact_immutable_frame_can_be_drawn" pass:correct&&completed&&self.va.lastCompletedSubmissionSerial>prior details:@{@"result":LRResultName(same),@"exactMetadataAndTextureReused":@YES,@"completedSerial":@(self.va.lastCompletedSubmissionSerial)}];
            self.pa.repeatExactContract=NO;self.pa.texture=self.cropA;
            [self guards];
        });
    });
}
- (void)guards {
    LGButtonOpticalState a=LRState(501,0),b=LRState(502,0);
    self.pa.ownerAlive=NO;LGLocalButtonRendererResult r=[self.va submitOpticalState:a enabled:YES];
    [self record:@"E_owner_expired_rejected_and_hidden" pass:r==LGLocalButtonRendererSourceRejected&&self.va.hidden details:@{@"result":LRResultName(r)}];self.pa.ownerAlive=YES;
    self.pa.staleAge=.20;r=[self.va submitOpticalState:a enabled:YES];
    [self record:@"E_source_older_than100ms_rejected" pass:r==LGLocalButtonRendererSourceRejected&&self.va.hidden details:@{@"result":LRResultName(r)}];self.pa.staleAge=0;
    uint64_t accepted=self.lastAcceptedA;
    if(accepted>1) {
        self.pa.forceGeneration=YES;self.pa.forcedGeneration=accepted-1;
        r=[self.va submitOpticalState:a enabled:YES];self.pa.forceGeneration=NO;
        [self record:@"E_regressive_frame_generation_rejected" pass:r==LGLocalButtonRendererSourceRejected&&self.va.hidden details:@{@"result":LRResultName(r),@"lastAccepted":@(accepted),@"attempted":@(accepted-1)}];
    }else [self record:@"E_regressive_frame_generation_rejected" pass:NO details:@{@"status":@"NOT_RUN: fewer than two actually accepted generations"}];
    self.tb.enabled=NO;r=[self.vb submitOpticalState:b enabled:YES];
    [self record:@"F_disabled_UIControl_stops_source" pass:r==LGLocalButtonRendererInactive&&self.vb.hidden details:@{@"result":LRResultName(r)}];self.tb.enabled=YES;
    [self.tb removeFromSuperview];r=[self.vb submitOpticalState:b enabled:YES];
    [self record:@"F_detached_target_stops_source" pass:r==LGLocalButtonRendererInactive&&self.vb.hidden details:@{@"result":LRResultName(r)}];
    a.eligible=false;r=[self.va submitOpticalState:a enabled:YES];
    [self record:@"F_ineligible_state_stops_source" pass:r==LGLocalButtonRendererInactive&&self.va.hidden details:@{@"result":LRResultName(r)}];
    a=LRState(501,0);r=[self.va submitOpticalState:a enabled:NO];
    [self record:@"F_feature_off_stops_source" pass:r==LGLocalButtonRendererDisabled&&self.va.hidden details:@{@"result":LRResultName(r)}];
    dispatch_async(dispatch_get_main_queue(),^{[self expiry];});
}
- (void)expiry {
    LGButtonOpticalState a=LRState(501,0);uint64_t before=self.va.lastCompletedSubmissionSerial;
    LGLocalButtonRendererResult r=[self.va submitOpticalState:a enabled:YES];
    uint64_t generation=self.pa.lastContract.frameGeneration;
    BOOL ready=r==LGLocalButtonRendererReadyForNextDraw;
    LRAwait(CACurrentMediaTime()+2.0,^BOOL {
        return !ready || (self.va.lastCompletedSubmissionSerial>before&&self.va.lastCommandBufferSucceeded&&!self.va.hidden);
    },^(BOOL seen){
        BOOL drew=ready&&seen&&self.va.lastCompletedSubmissionSerial>before;
        CFTimeInterval observed=CACurrentMediaTime();uint64_t serial=self.va.lastCompletedSubmissionSerial;
        LRDelay(.150,^{
            BOOL ended=NO;
            @synchronized(self.pa.leases){
                for(NSDictionary *event in self.pa.leases.events)
                    if([event[@"generation"] unsignedLongLongValue]==generation&&[event[@"endedAtMonotonic"] doubleValue]>=observed)ended=YES;
            }
            [self record:@"E_expiry_hides_after100ms_without_new_draw" pass:drew&&self.va.hidden details:@{@"drawCompleted":@(drew),@"hidden":@(self.va.hidden),@"elapsedAfterObservedCompletion":@(CACurrentMediaTime()-observed),@"sourceMaxAgeUnchanged":@.100,@"completedSerial":@(serial)}];
            [self record:@"G_frame_lease_ended_after_observed_GPU_completion" pass:drew&&ended details:@{@"generation":@(generation),@"leaseEnded":@(ended)}];
            uint64_t prior=self.va.lastCompletedSubmissionSerial;
            LGLocalButtonRendererResult next=[self.va submitOpticalState:LRState(501,0) enabled:YES];
            [self.va invalidateLocalSource];
            LRDelay(.150,^{
                [self record:@"G_pending_invalidation_does_not_revive" pass:next==LGLocalButtonRendererReadyForNextDraw&&self.va.hidden&&self.va.lastCompletedSubmissionSerial==prior details:@{@"hidden":@(self.va.hidden),@"serialUnchanged":@(self.va.lastCompletedSubmissionSerial==prior)}];
                [self finish];
            });
        });
    });
}
- (void)finish {
    if(self.finished)return;self.finished=YES;
    [self.va invalidateLocalSource];[self.vb invalidateLocalSource];
    [self.va removeFromSuperview];[self.vb removeFromSuperview];[self.ta removeFromSuperview];[self.tb removeFromSuperview];
    BOOL pass=self.checks.count>=15;
    for(NSDictionary *r in self.checks)pass=pass&&[r[@"pass"] boolValue];
    self.report[@"checks"]=self.checks;self.report[@"drawFrames"]=self.draws;
    self.report[@"acceptanceStatus"]=pass?@"REAL_CLASS_DRAW_AND_GPU_COMPLETION_PASS_WITH_STRESS_LIMITS":@"REAL_CLASS_RUNTIME_PARTIAL_OR_FAIL";
    self.report[@"runtimeLimitations"]=@{@"systemBackgroundProvider":@"NOT_IMPLEMENTED",@"pixelReadback":@"NOT_RUN; framebufferOnlyYES",@"threeInFlightGPUCapStress":@"NOT_OBSERVED; frame leases are not GPU concurrency",@"oldCompletedCallbackAfterInvalidationRace":@"NOT_OBSERVED: pending invalidation only",@"realUIKitTouch":@NO,@"systemLiveBackdrop":@NO};
    if(self.pa&&self.pb)self.report[@"leaseAccounting"]=@{@"activeA":@(self.pa.leases.active),@"maximumOutstandingFrameLeasesA":@(self.pa.leases.maximum),@"endedA":@(self.pa.leases.ended),@"leaseEventsA":[self.pa.leases.events copy],@"activeB":@(self.pb.leases.active),@"endedB":@(self.pb.leases.ended)};
    self.report[@"createdAt"]=[[NSISO8601DateFormatter new]stringFromDate:[NSDate date]];
    NSString *name=[NSString stringWithFormat:@"native-local-renderer-%@.json",self.report[@"runID"]];
    NSURL *docs=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSError *error=nil;NSData *data=[NSJSONSerialization dataWithJSONObject:self.report options:NSJSONWritingPrettyPrinted error:&error];
    BOOL written=data&&[data writeToURL:[docs URLByAppendingPathComponent:name] options:NSDataWritingAtomic error:&error];
    self.report[@"reportWritten"]=@(written);self.report[@"reportWriteError"]=error.localizedDescription?:@"";
    if(written){data=[NSJSONSerialization dataWithJSONObject:self.report options:NSJSONWritingPrettyPrinted error:nil];if(data)[data writeToURL:[docs URLByAppendingPathComponent:name] options:NSDataWritingAtomic error:nil];}
    if(self.completion)self.completion([NSString stringWithFormat:@"%@ · %@",self.report[@"acceptanceStatus"],written?name:@"report write failed"],name);
    self.completion=nil;self.container=nil;
}
@end
void RunLocalRendererRuntimeProbe(id<MTLDevice> device,id<MTLCommandQueue> queue,
                                  id<MTLTexture> appInputTexture,UIView *container,
                                  void (^completion)(NSString *,NSString *)) {
    LRAsyncProbe *probe=[LRAsyncProbe new];probe.device=device;probe.queue=queue;
    probe.input=appInputTexture;probe.container=container;probe.completion=completion;
    [probe start]; // async stages retain the context until final report/cleanup
}
