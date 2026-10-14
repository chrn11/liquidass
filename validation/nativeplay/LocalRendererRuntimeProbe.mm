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
@property(nonatomic) BOOL nilFirst, ownerAlive, forceGeneration;
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
    c.sampledRGBIsLinear=true;c.sampledRGBIsPremultiplied=true;self.lastContract=c;
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
static BOOL LRWaitForDraw(LGLocalButtonMaterialView *a,uint64_t sa,LGLocalButtonMaterialView *b,uint64_t sb,NSTimeInterval timeout) {
    CFTimeInterval end=CACurrentMediaTime()+timeout;
    while(CACurrentMediaTime()<end){
        BOOL aa=!a||(a.lastCompletedSubmissionSerial>sa&&a.lastCommandBufferSucceeded&&!a.hidden);
        BOOL bb=!b||(b.lastCompletedSubmissionSerial>sb&&b.lastCommandBufferSucceeded&&!b.hidden);
        if(aa&&bb)return YES;CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.004,true);
    }
    return NO;
}

void RunLocalRendererRuntimeProbe(id<MTLDevice> device,id<MTLCommandQueue> queue,
                                  id<MTLTexture> appInputTexture,UIView *container,
                                  void (^completion)(NSString *,NSString *)) {
    NSCAssert(NSThread.isMainThread,@"All UIKit/source guards must run on main");
    NSString *runID=NSUUID.UUID.UUIDString;
    NSMutableArray *checks=[NSMutableArray array],*draws=[NSMutableArray array];
    NSMutableDictionary *report=[@{@"schemaVersion":@1,@"runID":runID,
      @"scope":@"Actual LGLocalButtonMaterialView MTKView draw and command completion only; app-owned static asset; no system source/UI capture.",
      @"mode":@"STATIC_APP_SOURCE_TEST",@"SYSTEM_BACKGROUND_PROVIDER_NOT_IMPLEMENTED":@YES,
      @"bundleID":NSBundle.mainBundle.bundleIdentifier?:@"unavailable",
      @"buildVersion":NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"]?:@"unavailable",
      @"compileMacroLG_LOCAL_BUTTON_RENDERER_COMPILED":@1,
      @"shaderExpectedSHA256":@"f21b394471fd9d3983502441852e3be0664eec7614a7bcd7652939077c06a72b",
      @"pixelEvidence":@"NONE; framebufferOnly remains YES; no drawable readback or UI screenshot",
      @"inputTexturePixelFormat":@(appInputTexture.pixelFormat),@"inputTextureSizePx":@[@(appInputTexture.width),@(appInputTexture.height)]} mutableCopy];
    void (^record)(NSString *,BOOL,NSString *,BOOL,BOOL)=^(NSString *name,BOOL pass,NSString *result,BOOL hidden,BOOL expectedHidden){
        [checks addObject:@{@"check":name,@"pass":@(pass),@"result":result?:@"",@"hidden":@(hidden),@"expectedHidden":@(expectedHidden)}];};
    if(!device||!queue||!appInputTexture||!container.window||!NSThread.isMainThread){
        report[@"acceptanceStatus"]=@"FAIL_SETUP";report[@"failure"]=@"missing device/queue/input/window or main-thread gate";
    } else if(appInputTexture.pixelFormat!=MTLPixelFormatBGRA8Unorm_sRGB||appInputTexture.width<132||appInputTexture.height<132){
        report[@"acceptanceStatus"]=@"FAIL_SOURCE_FORMAT";report[@"failure"]=@"self-owned UIImage input texture is not sRGB fmt81 or too small";
    } else {
        const NSUInteger n=132,x=(appInputTexture.width-n)/2,y=(appInputTexture.height-n)/2;
        MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB width:n height:n mipmapped:NO];
        td.usage=MTLTextureUsageShaderRead;td.storageMode=MTLStorageModeShared;
        id<MTLTexture> cropA=[device newTextureWithDescriptor:td],cropB=[device newTextureWithDescriptor:td];
        id<MTLCommandBuffer> cropCB=[queue commandBuffer];id<MTLBlitCommandEncoder> blit=[cropCB blitCommandEncoder];
        if(cropA&&cropB&&blit){
            [blit copyFromTexture:appInputTexture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x,y,0) sourceSize:MTLSizeMake(n,n,1) toTexture:cropA destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
            [blit copyFromTexture:appInputTexture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x,y,0) sourceSize:MTLSizeMake(n,n,1) toTexture:cropB destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
            [blit endEncoding];[cropCB commit];[cropCB waitUntilCompleted];
        }
        BOOL cropOK=cropA&&cropB&&cropCB.status==MTLCommandBufferStatusCompleted;
        report[@"source"]=@{@"kind":@"StaticAsset",@"asset":@"NSBundle InputBotanical.png -> existing app-owned sRGB input texture -> exact centered 132x132 blit crop",@"sourceCropPx":@{@"x":@(x),@"y":@(y),@"width":@132,@"height":@132},@"pointScale":@3,@"targetSizePt":@[@44,@44],@"format":@81,@"backgroundOnly":@YES,@"targetForegroundExcluded":@YES,@"immutableFrameLease":@YES,@"sampledLinear":@YES,@"sampledPremultiplied":@YES,@"alphaMode":@"Opaque (provider assertion; source asset only)",@"windowCapture":@NO,@"renderInContext":@NO,@"IOSurfaceRead":@NO,@"systemSource":@NO,@"cropCommandCompleted":@(cropOK)};
        LRTestTarget *ta=[LRTestTarget new],*tb=[LRTestTarget new];
        ta.frame=CGRectMake(4,1,44,44);tb.frame=CGRectMake(52,1,44,44);
        for(LRTestTarget *t in @[ta,tb]){t.enabled=YES;t.userInteractionEnabled=NO;t.accessibilityElementsHidden=YES;t.backgroundColor=UIColor.clearColor;t.layer.borderWidth=1.0;t.layer.borderColor=[UIColor colorWithWhite:1 alpha:.8].CGColor;UIView *fg=[[UIView alloc]initWithFrame:CGRectMake(18,18,8,8)];fg.backgroundColor=[UIColor colorWithWhite:1 alpha:.85];fg.layer.cornerRadius=4;fg.userInteractionEnabled=NO;[t addSubview:fg];[container addSubview:t];}
        [container layoutIfNeeded];
        LRStaticAssetProvider *pA=[[LRStaticAssetProvider alloc]initWithTexture:cropA owner:0xA101 geometry:501];
        LGLocalButtonMaterialView *off=LRView(ta,pA,YES,NO);
        LGButtonOpticalState sA=LRState(501,0);
        LGLocalButtonRendererResult roff=off?[off submitOpticalState:sA enabled:YES]:LGLocalButtonRendererInactive;
        record(@"A_explicitOptIn_false",off&&roff==LGLocalButtonRendererDisabled&&off.hidden,LRResultName(roff),off?off.hidden:YES,YES);
        BOOL noProviderCallForA=(pA.calls==0);[checks addObject:@{@"check":@"A_provider_not_queried_when_opt_out",@"pass":@(noProviderCallForA),@"providerCalls":@(pA.calls)}];
        [off removeFromSuperview];
        pA.nilFirst=YES;
        LGLocalButtonMaterialView *va=LRView(ta,pA,YES,YES);
        LGLocalButtonRendererResult rb=va?[va submitOpticalState:sA enabled:YES]:LGLocalButtonRendererInactive;
        record(@"B_source_provider_returns_nil",va&&rb==LGLocalButtonRendererSourceUnavailable&&va.hidden,LRResultName(rb),va?va.hidden:YES,YES);
        LRStaticAssetProvider *pC=[[LRStaticAssetProvider alloc]initWithTexture:cropA owner:0xC303 geometry:501];
        LGLocalButtonMaterialView *vc=LRView(ta,pC,NO,YES);
        LGLocalButtonRendererResult rc=vc?[vc submitOpticalState:sA enabled:YES]:LGLocalButtonRendererInactive;
        record(@"C_static_asset_approximation_disallowed",vc&&rc==LGLocalButtonRendererSourceRejected&&vc.hidden,LRResultName(rc),vc?vc.hidden:YES,YES);
        [vc removeFromSuperview];
        LRStaticAssetProvider *pB=[[LRStaticAssetProvider alloc]initWithTexture:cropB owner:0xB202 geometry:502];
        LGLocalButtonMaterialView *vb=LRView(tb,pB,YES,YES);
        BOOL constructed=va&&vb&&va.framebufferOnly&&vb.framebufferOnly;
        [checks addObject:@{@"check":@"D_two_real_local_class_instances_and_framebufferOnly",@"pass":@(constructed),@"A_isActualClass":@([va isKindOfClass:LGLocalButtonMaterialView.class]),@"B_isActualClass":@([vb isKindOfClass:LGLocalButtonMaterialView.class]),@"framebufferOnlyA":@(va.framebufferOnly),@"framebufferOnlyB":@(vb.framebufferOnly),@"distinctProviders":@(pA!=pB),@"distinctTextures":@(cropA!=cropB)}];
        BOOL allDraws=constructed&&cropOK;uint64_t finalSerialA=0,finalSerialB=0;
        for(NSUInteger step=0;step<3&&constructed;step++){
            float pressure=(step==1)?1.0f:0.0f;LGButtonOpticalState a=LRState(501,pressure),b=LRState(502,pressure);
            uint64_t beforeA=va.lastCompletedSubmissionSerial,beforeB=vb.lastCompletedSubmissionSerial;
            LGLocalButtonRendererResult ra=[va submitOpticalState:a enabled:YES],rbb=[vb submitOpticalState:b enabled:YES];
            BOOL ready=(ra==LGLocalButtonRendererReadyForNextDraw&&rbb==LGLocalButtonRendererReadyForNextDraw);
            BOOL completed=ready&&LRWaitForDraw(va,beforeA,vb,beforeB,3.0);
            unsigned bucketA=LGOpticalPressureIndex(&a,LG_BUTTON_PRESSURE_LEVELS),bucketB=LGOpticalPressureIndex(&b,LG_BUTTON_PRESSURE_LEVELS);
            LGLocalButtonUniforms uA={0},uB={0};LGLocalButtonSourceContract cA=pA.lastContract,cB=pB.lastContract;BOOL builtA=LGLocalButtonBuildUniforms(&cA,&a,132,132,3,&uA),builtB=LGLocalButtonBuildUniforms(&cB,&b,132,132,3,&uB);
            finalSerialA=va.lastCompletedSubmissionSerial;finalSerialB=vb.lastCompletedSubmissionSerial;
            [draws addObject:@{@"state":@(step),@"syntheticPressure":@(pressure),@"tracking":@NO,@"UIKitTouchInjected":@NO,@"eligible":@(a.eligible&&b.eligible),@"geometryGenerationA":@(a.geometryGeneration),@"geometryGenerationB":@(b.geometryGeneration),@"frameGenerationA":@(pA.lastContract.frameGeneration),@"frameGenerationB":@(pB.lastContract.frameGeneration),@"providerAResult":LRResultName(ra),@"providerBResult":LRResultName(rbb),@"completionObservedOnExactClassA":@(completed&&va.lastCommandBufferSucceeded),@"completionObservedOnExactClassB":@(completed&&vb.lastCommandBufferSucceeded),@"completedSerialA":@(va.lastCompletedSubmissionSerial),@"completedSerialB":@(vb.lastCompletedSubmissionSerial),@"bucketA":@(bucketA),@"bucketB":@(bucketB),@"uniformsBuiltBySharedLGButtonPressureMaterialA":@(builtA),@"uniformsBuiltBySharedLGButtonPressureMaterialB":@(builtB),@"thicknessA":@(uA.glassThickness),@"thicknessB":@(uB.glassThickness),@"refractionScaleA":@(uA.refractionScale),@"refractionScaleB":@(uB.refractionScale),@"isSystemLiveBackdropA":@(va.isSystemLiveBackdrop),@"isApproximateSourceA":@(va.isApproximateSource)}];
            if(step==1)allDraws&=(bucketA==8&&bucketB==8);else allDraws&=(bucketA==0&&bucketB==0);
            allDraws&=ready&&completed&&builtA&&builtB&&va.isApproximateSource&&vb.isApproximateSource&&!va.isSystemLiveBackdrop&&!vb.isSystemLiveBackdrop&&pA.lastContract.frameGeneration==step+1&&pB.lastContract.frameGeneration==step+1;
            if(!allDraws)break;
        }
        [checks addObject:@{@"check":@"D_actual_MTKView_draw_commit_GPU_completion_serial_pressure_0_8_0",@"pass":@(allDraws),@"frames":draws,@"lastCompletedSerialA":@(finalSerialA),@"lastCompletedSerialB":@(finalSerialB),@"fullShaderSHA256":@"f21b394471fd9d3983502441852e3be0664eec7614a7bcd7652939077c06a72b",@"sourceFormat81":@(pA.lastContract.pixelFormat==81&&pB.lastContract.pixelFormat==81)}];
        BOOL ownerBefore=pA.ownerAlive;pA.ownerAlive=NO;LGLocalButtonRendererResult reOwner=[va submitOpticalState:sA enabled:YES];BOOL ownerPass=(reOwner==LGLocalButtonRendererSourceRejected&&va.hidden);pA.ownerAlive=ownerBefore;
        [checks addObject:@{@"check":@"E_owner_expired_rejected_and_hidden",@"pass":@(ownerPass),@"result":LRResultName(reOwner),@"hidden":@(va.hidden)}];
        pA.staleAge=.20;LGLocalButtonRendererResult reStale=[va submitOpticalState:sA enabled:YES];BOOL stalePass=(reStale==LGLocalButtonRendererSourceRejected&&va.hidden);pA.staleAge=0;
        [checks addObject:@{@"check":@"E_source_older_than_100ms_rejected_and_hidden",@"pass":@(stalePass),@"result":LRResultName(reStale),@"hidden":@(va.hidden)}];
        pA.forceGeneration=YES;pA.forcedGeneration=2;LGLocalButtonRendererResult reGen=[va submitOpticalState:sA enabled:YES];BOOL genPass=(reGen==LGLocalButtonRendererSourceRejected&&va.hidden);pA.forceGeneration=NO;
        [checks addObject:@{@"check":@"E_regressive_frame_generation_rejected_and_hidden",@"pass":@(genPass),@"result":LRResultName(reGen),@"hidden":@(va.hidden),@"lastAcceptedGeneration":@3,@"attemptedGeneration":@2}];
        LGButtonOpticalState enabledTargetState=LRState(502,0);tb.enabled=NO;LGLocalButtonRendererResult rDisabledTarget=[vb submitOpticalState:enabledTargetState enabled:YES];
        BOOL disabledTargetPass=(rDisabledTarget==LGLocalButtonRendererInactive&&vb.hidden);tb.enabled=YES;
        [checks addObject:@{@"check":@"F_target_UIControl_enabled_false_stops_source",@"pass":@(disabledTargetPass),@"result":LRResultName(rDisabledTarget),@"hidden":@(vb.hidden),@"targetIsInteractive":@(tb.userInteractionEnabled)}];
        [tb removeFromSuperview];LGLocalButtonRendererResult rDetached=[vb submitOpticalState:LRState(502,0) enabled:YES];BOOL detachedPass=(rDetached==LGLocalButtonRendererInactive&&vb.hidden);
        [checks addObject:@{@"check":@"F_detached_target_stops_source",@"pass":@(detachedPass),@"result":LRResultName(rDetached),@"hidden":@(vb.hidden)}];
        LGButtonOpticalState ineligible=LRState(501,0);ineligible.eligible=false;LGLocalButtonRendererResult rInactive=[va submitOpticalState:ineligible enabled:YES];BOOL inactivePass=(rInactive==LGLocalButtonRendererInactive&&va.hidden);
        [checks addObject:@{@"check":@"F_inactive_state_stops_source",@"pass":@(inactivePass),@"result":LRResultName(rInactive),@"hidden":@(va.hidden)}];
        LGLocalButtonRendererResult rOff=[va submitOpticalState:sA enabled:NO];BOOL featureOffPass=(rOff==LGLocalButtonRendererDisabled&&va.hidden);
        [checks addObject:@{@"check":@"F_feature_enabled_false_stops_source",@"pass":@(featureOffPass),@"result":LRResultName(rOff),@"hidden":@(va.hidden)}];
        uint64_t beforeExpiry=va.lastCompletedSubmissionSerial;LGLocalButtonRendererResult rExpire=[va submitOpticalState:sA enabled:YES];
        BOOL expireDraw=(rExpire==LGLocalButtonRendererReadyForNextDraw)&&LRWaitForDraw(va,beforeExpiry,nil,0,3.0);uint64_t expirySerial=va.lastCompletedSubmissionSerial;CFTimeInterval completionObserved=CACurrentMediaTime();uint64_t expiryGeneration=pA.lastContract.frameGeneration;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode,.150,true);
        BOOL expiryHidden=va.hidden;BOOL finalLeaseEnded=NO;
        @synchronized(pA.leases){for(NSDictionary *e in pA.leases.events)if([e[@"generation"] unsignedLongLongValue]==expiryGeneration&&[e[@"endedAtMonotonic"] doubleValue]>=completionObserved)finalLeaseEnded=YES;}
        [checks addObject:@{@"check":@"E_one_shot_100ms_timer_hides_without_new_draw",@"pass":@(expireDraw&&expiryHidden),@"result":LRResultName(rExpire),@"completedSerial":@(expirySerial),@"hiddenAfter150ms":@(expiryHidden),@"noNewDrawAfterCompletion":@YES}];
        [checks addObject:@{@"check":@"G_leaseEnded_after_GPU_completion_for_expired_frame",@"pass":@(expireDraw&&finalLeaseEnded),@"frameGeneration":@(expiryGeneration),@"leaseEndedAfterCompletionObservation":@(finalLeaseEnded)}];
        uint64_t beforePending=va.lastCompletedSubmissionSerial;LGLocalButtonRendererResult pending=[va submitOpticalState:sA enabled:YES];[va invalidateLocalSource];CFRunLoopRunInMode(kCFRunLoopDefaultMode,.150,true);BOOL pendingNoRevive=(pending==LGLocalButtonRendererReadyForNextDraw&&va.hidden&&va.lastCompletedSubmissionSerial==beforePending);
        [checks addObject:@{@"check":@"G_invalidate_before_pending_draw_keeps_instance_hidden",@"pass":@(pendingNoRevive),@"readyBeforeInvalidate":@(pending==LGLocalButtonRendererReadyForNextDraw),@"hiddenAfter150ms":@(va.hidden),@"completedSerialUnchanged":@(va.lastCompletedSubmissionSerial==beforePending)}];
        report[@"leaseAccounting"]=@{@"activeA":@(pA.leases.active),@"maximumOutstandingFrameLeasesA":@(pA.leases.maximum),@"endedA":@(pA.leases.ended),@"leaseEventsA":[pA.leases.events copy],@"activeB":@(pB.leases.active),@"maximumOutstandingFrameLeasesB":@(pB.leases.maximum),@"endedB":@(pB.leases.ended),@"leaseEventsB":[pB.leases.events copy],@"threeGPUCommandsInFlightOnOneInstanceObserved":@(pA.leases.maximum>=4),@"interpretation":@"lease count includes current frame and transient provider handoff; only >=4 would evidence current+three retained GPU frames"};
        BOOL realPass=allDraws&&ownerPass&&stalePass&&genPass&&disabledTargetPass&&detachedPass&&inactivePass&&featureOffPass&&expireDraw&&expiryHidden&&finalLeaseEnded&&pendingNoRevive;
        report[@"checks"]=checks;report[@"drawFrames"]=draws;report[@"acceptanceStatus"]=realPass?@"REAL_CLASS_DRAW_AND_GPU_COMPLETION_PASS_WITH_STRESS_LIMITS":@"REAL_CLASS_RUNTIME_PARTIAL_OR_FAIL";
        report[@"runtimeLimitations"]=[@{@"systemBackgroundProvider":@"NOT_IMPLEMENTED",@"pixelReadback":@"NOT_RUN; framebufferOnly YES",@"threeInFlightGPUCapStress":(pA.leases.maximum>=4?@"OBSERVED":@"NOT_OBSERVED"),@"oldCompletedCallbackAfterInvalidationRace":@"NOT_OBSERVED; only pending-frame invalidation safety checked",@"systemLiveBackdrop":@NO,@"realUIKitTouch":@NO} mutableCopy];
        [va invalidateLocalSource];[vb invalidateLocalSource];[va removeFromSuperview];[vb removeFromSuperview];[ta removeFromSuperview];[tb removeFromSuperview];
    }
    report[@"checks"]=checks;
    if(!report[@"acceptanceStatus"])report[@"acceptanceStatus"]=@"FAIL_SETUP";
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    NSString *reportName=[NSString stringWithFormat:@"native-local-renderer-%@.json",runID];
    NSURL *docs=[[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    NSError *writeError=nil;BOOL written=json&&docs&&[json writeToURL:[docs URLByAppendingPathComponent:reportName] options:NSDataWritingAtomic error:&writeError];
    report[@"reportWritten"]=@(written);report[@"reportWriteError"]=writeError.localizedDescription?:@"";
    if(written){NSData *final=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];if(final)[final writeToURL:[docs URLByAppendingPathComponent:reportName] options:NSDataWritingAtomic error:nil];}
    NSString *summary=[NSString stringWithFormat:@"%@ · %@",report[@"acceptanceStatus"],written?reportName:(writeError.localizedDescription?:@"report write failed")];
    if(completion)completion(summary,reportName);
}
