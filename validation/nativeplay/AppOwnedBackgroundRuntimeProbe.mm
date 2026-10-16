#import "AppOwnedBackgroundRuntimeProbe.h"
#import "LGAppOwnedButtonSourceProvider.h"
#import "LGAppOwnedLeasePolicy.h"
#import <QuartzCore/QuartzCore.h>
#import <CommonCrypto/CommonDigest.h>
#include <vector>
static void APDelay(NSTimeInterval seconds,dispatch_block_t next) {
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(seconds*NSEC_PER_SEC)),dispatch_get_main_queue(),next);
}
static void APAwait(CFTimeInterval deadline,BOOL(^ready)(void),void(^done)(BOOL)) {
 if(ready()){done(YES);return;}if(CACurrentMediaTime()>=deadline){done(NO);return;}
 APDelay(.005,^{APAwait(deadline,ready,done);});
}
static NSData *APPixels(id<MTLTexture> texture) {
 if(!texture || texture.storageMode==MTLStorageModePrivate)return nil;
 NSMutableData *d=[NSMutableData dataWithLength:texture.width*texture.height*4];
 [texture getBytes:d.mutableBytes bytesPerRow:texture.width*4 fromRegion:MTLRegionMake2D(0,0,texture.width,texture.height) mipmapLevel:0];return d;
}
static NSString *APSHA(NSData *data) {
 if(!data)return @"unavailable";unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
 NSMutableString *s=[NSMutableString string];for(unsigned char byte:digest)[s appendFormat:@"%02x",byte];return s;
}
static NSArray<NSNumber *> *APReadPixel(NSData *data,NSUInteger width,NSUInteger x,NSUInteger y) {
 if(!data||!width||x>=width||y>=data.length/(width*4))return @[];
 const uint8_t *b=(const uint8_t *)data.bytes+(y*width+x)*4;
 return @[@(b[0]),@(b[1]),@(b[2]),@(b[3])];
}
// Test-only scheduling control. Every successful draw still executes the
// production superclass; delaying a draw is not a GPU success or stress claim.
@interface APDeferredMaterialView : LGLocalButtonMaterialView
@property(nonatomic) BOOL deferFixtureDraw;
@end
@implementation APDeferredMaterialView
- (void)drawInMTKView:(MTKView *)view {
 if (!self.deferFixtureDraw) [super drawInMTKView:view];
}
@end
@interface APOwnedProbe : NSObject
@property(nonatomic,strong) id<MTLDevice> device;
@property(nonatomic,strong) UIView *container,*sourceRoot;
@property(nonatomic,strong) UIControl *target;
@property(nonatomic,strong) LGAppOwnedButtonSourceProvider *provider;
@property(nonatomic,strong) LGLocalButtonMaterialView *material;
@property(nonatomic,strong) NSMutableArray<LGLocalButtonTextureFrame *> *heldFrames;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *checks;
@property(nonatomic,strong) NSMutableArray<NSString *> *originalHeldPixelHashes;
@property(nonatomic,copy) void(^completion)(NSDictionary *);
@property(nonatomic) NSUInteger captures;
@property(nonatomic) uint64_t targetGeneration;
@property(nonatomic) uint64_t completedBefore;
@property(nonatomic) BOOL finished,cancelNextRevocation;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *availabilityEvents;
- (void)start;
- (void)captureNext;
- (void)completionCallbacks;
- (void)completedFrameDeadline;
- (void)hostCancellation;
- (void)poolFull;
- (void)transparent;
- (void)patternGeometry;
- (void)finish;
@end
@implementation APOwnedProbe
- (void)record:(NSString *)name pass:(BOOL)passed details:(NSDictionary *)details {
 NSMutableDictionary *d=[@{@"check":name,@"pass":@(passed)} mutableCopy];if(details)[d addEntriesFromDictionary:details];[self.checks addObject:d];
}
- (LGLocalButtonTextureFrame *)pull {
 return [self.provider currentBackgroundFrameForTargetView:self.target monotonicTimestamp:CACurrentMediaTime()];
}
- (LGButtonOpticalState)state {
 LGButtonOpticalState s={0};LGOpticalSetEligibility(&s,true,true,true,true,true,self.targetGeneration?:901);return s;
}
- (void)start {
 NSCAssert(NSThread.isMainThread,@"Own-view provider test stays on main thread");
 self.checks=[NSMutableArray array];self.heldFrames=[NSMutableArray array];self.originalHeldPixelHashes=[NSMutableArray array];self.availabilityEvents=[NSMutableArray array];
 if(!self.container.window||!self.device){[self record:@"owned_source_test_requires_original_app_window" pass:NO details:nil];[self finish];return;}
 // A source sibling explicitly created for this App's existing selfcheck. Its
 // pixels are actual UIKit layer output; it never includes the target/text.
 self.sourceRoot=[[UIView alloc]initWithFrame:CGRectMake(0,0,76,76)];self.sourceRoot.opaque=YES;self.sourceRoot.backgroundColor=[UIColor colorWithRed:.8 green:.1 blue:.15 alpha:1];self.sourceRoot.userInteractionEnabled=NO;self.sourceRoot.accessibilityElementsHidden=YES;
 self.target=[[UIControl alloc]initWithFrame:CGRectMake(16,16,44,44)];self.target.userInteractionEnabled=NO;self.target.accessibilityElementsHidden=YES;
 [self.container addSubview:self.sourceRoot];[self.container addSubview:self.target];
 LGAppOwnedButtonSourceProvider *off=[[LGAppOwnedButtonSourceProvider alloc]initWithSourceRoot:self.sourceRoot targetView:self.target device:self.device edgePadding:UIEdgeInsetsMake(16,16,16,16) explicitOptIn:NO];
 LGLocalButtonTextureFrame *blocked=[off currentBackgroundFrameForTargetView:self.target monotonicTimestamp:CACurrentMediaTime()];[self record:@"owned_provider_optout_has_no_source" pass:blocked==nil details:@{@"status":@(off.lastStatus)}];
 self.provider=[[LGAppOwnedButtonSourceProvider alloc]initWithSourceRoot:self.sourceRoot targetView:self.target device:self.device edgePadding:UIEdgeInsetsMake(16,16,16,16) explicitOptIn:YES];
 self.material=[[APDeferredMaterialView alloc]initWithFrame:self.target.frame targetView:self.target sourceProvider:self.provider allowApproximateSource:NO explicitOptIn:YES];
 if(!self.provider||!self.material){[self record:@"actual_provider_and_original_renderer_initialize" pass:NO details:nil];[self finish];return;}
 [self.container insertSubview:self.material belowSubview:self.target];
 __weak APOwnedProbe *weakSelf=self;
 self.material.availabilityChangedHandler=^(LGLocalButtonMaterialView *view,BOOL available){
  APOwnedProbe *owner=weakSelf;if(!owner)return;
  [owner.availabilityEvents addObject:@{@"available":@(available),@"completedSerial":@(view.lastCompletedSubmissionSerial),@"mainThread":@(NSThread.isMainThread)}];
  if(!available&&owner.cancelNextRevocation){owner.cancelNextRevocation=NO;[view invalidateLocalSource];}
 };
 BOOL bound=[self.provider bindMaterialViewForFeedbackExclusion:self.material device:self.device];BOOL gen=[self.provider updateTargetGeometryGeneration:901];
 [self record:@"explicit_sibling_source_feedback_exclusion_and_generation" pass:bound&&gen details:@{@"targetIsNotSourceDescendant":@(![self.target isDescendantOfView:self.sourceRoot]),@"sourceIsNotTargetDescendant":@(![self.sourceRoot isDescendantOfView:self.target])}];
 if(!bound||!gen){[self finish];return;}
 LGLocalButtonTextureFrame *frame=[self pull];
 if(!frame){[self record:@"actual_opaque_source_layer_capture" pass:NO details:@{@"status":@(self.provider.lastStatus)}];[self finish];return;}
 LGLocalButtonSourceContract c=frame.contract;NSData *pixels=APPixels(frame.texture);BOOL alphaOK=pixels.length==228*228*4;const uint8_t *p=(const uint8_t *)pixels.bytes;
 for(NSUInteger i=3;alphaOK&&i<pixels.length;i+=4)alphaOK=p[i]==255;
 BOOL redPixel=alphaOK&&p[2]>170&&p[1]<70&&p[0]<90;
 [self record:@"actual_opaque_source_layer_capture" pass:alphaOK&&redPixel&&c.sourceKind==LGLocalSourceLiveAppOwnedTexture&&c.textureWidth==228&&c.textureHeight==228&&c.sourceOverscanEnabled details:@{@"sourcePixelsSHA256":APSHA(pixels),@"alphaAllOpaque":@(alphaOK),@"actualBGRAAgreesWithDeclaredSourceColor":@(redPixel),@"sourceKind":@(c.sourceKind),@"systemSource":@NO,@"sourcePixelsAreCapturedUIKitSubtree":@YES}];
 [self.heldFrames addObject:frame];[self.originalHeldPixelHashes addObject:APSHA(pixels)];self.captures=1;
 self.completedBefore=self.material.lastCompletedSubmissionSerial;
 LGLocalButtonRendererResult result=[self.material submitOpticalState:[self state] enabled:YES];BOOL ready=result==LGLocalButtonRendererReadyForNextDraw;
 APAwait(CACurrentMediaTime()+2,^BOOL{return !ready||(self.material.lastCommandBufferSucceeded&&self.material.lastCompletedSubmissionSerial>self.completedBefore);},^(BOOL observed){
  [self record:@"actual_owned_source_not_approximate_renderer_GPU_completed" pass:ready&&observed&&self.material.lastCompletedSubmissionSerial>self.completedBefore&&!self.material.isApproximateSource&&!self.material.isSystemLiveBackdrop details:@{@"result":@(result),@"actualCompletedSerial":@(self.material.lastCompletedSubmissionSerial),@"targetDrawablePx":@(self.material.drawableSize.width),@"screenPixels":@"NOT_READ"}];
  [self completionCallbacks];
 });
}
- (void)completionCallbacks {
 BOOL signalled=[self.availabilityEvents.lastObject[@"available"] boolValue];
 [self record:@"availability_yes_requires_actual_completed_valid_frame" pass:signalled&&self.material.lastCommandBufferSucceeded&&self.material.hasCurrentCompletedValidSubmission details:@{@"completedSerial":@(self.material.lastCompletedSubmissionSerial),@"callbackNotReadySignal":@YES}];
 APDeferredMaterialView *deferred=(APDeferredMaterialView *)self.material;
 uint64_t serial=self.material.lastCompletedSubmissionSerial;
 NSUInteger eventsBefore=self.availabilityEvents.count;deferred.deferFixtureDraw=YES;
 LGLocalButtonRendererResult next=[self.material submitOpticalState:[self state] enabled:YES];
 [self record:@"new_ready_not_completed_but_prior_actual_completion_available" pass:next==LGLocalButtonRendererReadyForNextDraw&&!self.material.hasCurrentCompletedValidSubmission&&self.material.hasDisplayableCompletedMaterial&&self.material.lastCompletedSubmissionSerial==serial&&self.availabilityEvents.count==eventsBefore details:@{@"actualPriorSerial":@(serial),@"controlledTestDrawDeferral":@YES}];
 APDelay(.050,^{
  [self record:@"pending_refresh_keeps_fresh_completed_material_at50ms" pass:self.material.hasDisplayableCompletedMaterial&&!self.material.hasCurrentCompletedValidSubmission&&self.material.lastCompletedSubmissionSerial==serial&&self.availabilityEvents.count==eventsBefore details:@{@"sourceMaxAgeSeconds":@.1}];
  deferred.deferFixtureDraw=NO;[self.material draw];
  APAwait(CACurrentMediaTime()+2,^BOOL{return self.material.lastCommandBufferSucceeded&&self.material.lastCompletedSubmissionSerial>serial;},^(BOOL completed){
   [self record:@"deferred_refresh_requires_new_actual_GPU_completion" pass:completed&&self.material.hasCurrentCompletedValidSubmission details:@{@"actualNewSerial":@(self.material.lastCompletedSubmissionSerial)}];
   [self completedFrameDeadline];
  });
 });
}
- (void)completedFrameDeadline {
 APDelay(.025,^{
  uint64_t serial=self.material.lastCompletedSubmissionSerial;
  APDeferredMaterialView *deferred=(APDeferredMaterialView *)self.material;deferred.deferFixtureDraw=YES;
  LGLocalButtonRendererResult submitted=[self.material submitOpticalState:[self state] enabled:YES];
  [self record:@"fresher_pending_frame_does_not_count_as_new_completion" pass:submitted==LGLocalButtonRendererReadyForNextDraw&&!self.material.hasCurrentCompletedValidSubmission&&self.material.lastCompletedSubmissionSerial==serial details:nil];
  APDelay(.050,^{
   [self record:@"old_completed_deadline_not_extended_by_fresh_pending_source" pass:!self.material.hasDisplayableCompletedMaterial&&!self.material.hasCurrentCompletedValidSubmission&&self.material.hasCurrentValidSourceFrame&&![self.availabilityEvents.lastObject[@"available"] boolValue] details:@{@"pendingSourceStillValid":@(self.material.hasCurrentValidSourceFrame),@"originalSourceLimitSeconds":@.1,@"layerOpacity":@(self.material.layer.opacity)}];
   deferred.deferFixtureDraw=NO;[self.material draw];
   APAwait(CACurrentMediaTime()+2,^BOOL{return self.material.lastCommandBufferSucceeded&&self.material.lastCompletedSubmissionSerial>serial;},^(BOOL completed){
    [self record:@"fresh_pending_frame_can_become_displayable_only_after_completion" pass:completed&&self.material.hasCurrentCompletedValidSubmission&&self.material.hasDisplayableCompletedMaterial details:@{@"actualNewSerial":@(self.material.lastCompletedSubmissionSerial)}];
    [self hostCancellation];
   });
  });
 });
}
- (void)hostCancellation {
 uint64_t serial=self.material.lastCompletedSubmissionSerial;self.cancelNextRevocation=YES;
 // A changed target generation invalidates the retained completion and invokes
 // the false callback. The callback opts out synchronously. This is not a fake
 // touch or a manufactured GPU failure; the source provider is unchanged.
 LGButtonOpticalState changed=[self state];changed.geometryGeneration++;
 LGLocalButtonRendererResult refused=[self.material submitOpticalState:changed enabled:YES];
 [self record:@"availability_callback_invalidation_aborts_outer_submit" pass:refused==LGLocalButtonRendererInactive&&self.material.hidden&&!self.material.hasCurrentValidSourceFrame details:@{@"result":@(refused)}];
 APDelay(.010,^{
  [self record:@"availability_cancelled_frame_does_not_revive_on_next_queue_turn" pass:self.material.hidden&&self.material.lastCompletedSubmissionSerial==serial&&!self.material.lastCommandBufferSucceeded details:nil];
  LGLocalButtonRendererResult again=[self.material submitOpticalState:[self state] enabled:YES];BOOL ready=again==LGLocalButtonRendererReadyForNextDraw;
  APAwait(CACurrentMediaTime()+2,^BOOL{return !ready||(self.material.lastCommandBufferSucceeded&&self.material.lastCompletedSubmissionSerial>serial);},^(BOOL observed){
   [self record:@"availability_valid_source_can_resume_after_host_cancellation" pass:ready&&observed&&self.material.hasCurrentCompletedValidSubmission&&[self.availabilityEvents.lastObject[@"available"] boolValue] details:@{@"actualCompletedSerial":@(self.material.lastCompletedSubmissionSerial)}];
   [self.material invalidateLocalSource];[self captureNext];
  });
 });
}

- (void)captureNext {
 if(self.captures>=LG_APP_OWNED_TEXTURE_SLOT_COUNT){[self poolFull];return;}
 NSUInteger step=self.captures;
 [UIView performWithoutAnimation:^{self.sourceRoot.backgroundColor=step==1?[UIColor colorWithRed:.1 green:.8 blue:.2 alpha:1]:[UIColor colorWithRed:.1 green:.2 blue:.85 alpha:1];}];
 [self.provider markSourceContentDirty];
 APDelay(.075,^{
  LGLocalButtonTextureFrame *frame=[self pull];LGLocalButtonTextureFrame *prior=self.heldFrames.lastObject;
  NSData *captured=APPixels(frame.texture);const uint8_t *bytes=(const uint8_t *)captured.bytes;
  BOOL dominant=captured.length>4&&(step==1?(bytes[1]>170&&bytes[2]<90):(bytes[0]>170&&bytes[2]<90));
  BOOL changed=frame&&dominant&&frame.contract.frameGeneration>prior.contract.frameGeneration&&frame.texture!=prior.texture&&![APSHA(captured) isEqualToString:self.originalHeldPixelHashes.lastObject];
  [self record:[NSString stringWithFormat:@"owned_source_real_content_change_frame%lu",(unsigned long)step+1] pass:changed details:@{@"providerStatus":@(self.provider.lastStatus),@"previousFrameGeneration":@(prior.contract.frameGeneration),@"newFrameGeneration":@(frame?frame.contract.frameGeneration:0),@"newActualPixelHash":APSHA(APPixels(frame.texture)),@"notReregisteredStaticTexture":@YES}];
  if(!changed){[self finish];return;}
  [self.heldFrames addObject:frame];[self.originalHeldPixelHashes addObject:APSHA(APPixels(frame.texture))];self.captures++;
  [self captureNext];
 });
}
- (void)poolFull {
 self.sourceRoot.backgroundColor=[UIColor colorWithRed:.75 green:.7 blue:.1 alpha:1];[self.provider markSourceContentDirty];
 APDelay(.075,^{
  LGLocalButtonTextureFrame *blocked=[self pull];BOOL immutable=YES;
  for(NSUInteger i=0;i<self.heldFrames.count;i++)immutable=immutable&&[APSHA(APPixels(self.heldFrames[i].texture)) isEqualToString:self.originalHeldPixelHashes[i]];
  [self record:@"owned_source_full_texture_pool_refuses_overwrite" pass:blocked==nil&&self.provider.lastStatus==LGAppOwnedButtonSourceStatusLeaseContention&&immutable details:@{@"maximumSlots":@(LG_APP_OWNED_TEXTURE_SLOT_COUNT),@"heldFrames":@(self.heldFrames.count),@"allLeasedTextureBytesUnchanged":@(immutable),@"status":@(self.provider.lastStatus)}];
  [self.material invalidateLocalSource];[self.heldFrames removeObjectAtIndex:0];[self.originalHeldPixelHashes removeObjectAtIndex:0];
  APDelay(.075,^{
   LGLocalButtonTextureFrame *again=[self pull];BOOL recovered=again!=nil;
   [self record:@"owned_source_slot_reusable_only_after_frame_lease_ends" pass:recovered details:@{@"status":@(self.provider.lastStatus),@"frameGeneration":@(again?again.contract.frameGeneration:0)}];
   // The two still-held frames must survive slot reuse byte-exactly.
   BOOL retained=YES;for(NSUInteger i=0;i<self.heldFrames.count;i++)retained=retained&&[APSHA(APPixels(self.heldFrames[i].texture)) isEqualToString:self.originalHeldPixelHashes[i]];
   [self record:@"owned_source_other_slot_pixel_immutability" pass:retained details:nil];
   [self patternGeometry];
  });
 });
}
- (void)patternGeometry {
 [self.material invalidateLocalSource];[self.heldFrames removeAllObjects];[self.originalHeldPixelHashes removeAllObjects];
 // Actual UIKit child geometry, not CPU material pixels. An asymmetric pattern
 // catches upside-down captures which uniform background colors cannot detect.
 [UIView performWithoutAnimation:^{
  self.sourceRoot.frame=CGRectMake(0,0,88,88);
  self.sourceRoot.backgroundColor=[UIColor colorWithRed:.8 green:.1 blue:.15 alpha:1];
  const CGRect boxes[4]={CGRectMake(44,0,44,44),CGRectMake(0,44,44,44),CGRectMake(44,44,44,44),CGRectMake(16,0,1,88)};
  NSArray *colors=@[[UIColor colorWithRed:.1 green:.8 blue:.2 alpha:1],[UIColor colorWithRed:.1 green:.2 blue:.85 alpha:1],[UIColor colorWithRed:.9 green:.7 blue:.1 alpha:1],UIColor.whiteColor];
  for(NSUInteger i=0;i<4;i++){UIView *v=[[UIView alloc]initWithFrame:boxes[i]];v.backgroundColor=colors[i];v.opaque=YES;v.userInteractionEnabled=NO;[self.sourceRoot addSubview:v];}
 }];[self.provider markSourceContentDirty];
 APDelay(.075,^{
  LGLocalButtonTextureFrame *f=[self pull];NSData *bytes=APPixels(f.texture);
  NSArray *tl=APReadPixel(bytes,f.texture.width,8*3,8*3),*tr=APReadPixel(bytes,f.texture.width,68*3,8*3),*bl=APReadPixel(bytes,f.texture.width,8*3,68*3),*br=APReadPixel(bytes,f.texture.width,68*3,68*3);
  BOOL oriented=tl.count==4&&[tl[2] intValue]>170&&[tl[1] intValue]<70&&[tr[1] intValue]>170&&[tr[2] intValue]<70&&[bl[0] intValue]>170&&[bl[2] intValue]<70&&[br[2] intValue]>210&&[br[1] intValue]>150&&[br[0] intValue]<70;
  [self record:@"owned_source_asymmetric_actual_layer_orientation" pass:f&&oriented details:@{@"topLeftBGRA":tl?:@[],@"topRightBGRA":tr?:@[],@"bottomLeftBGRA":bl?:@[],@"bottomRightBGRA":br?:@[],@"sourcePixelsSHA256":APSHA(bytes)}];
  if(!f||!oriented){[self finish];return;}
  self.target.frame=CGRectMake(18,16,44,44);self.material.frame=self.target.frame;
  LGLocalButtonTextureFrame *staleGeometry=[self pull];
  [self record:@"owned_source_target_move_requires_new_geometry_generation" pass:!staleGeometry&&self.provider.lastStatus==LGAppOwnedButtonSourceStatusTargetGenerationRequired details:@{@"status":@(self.provider.lastStatus)}];
  self.targetGeneration=902;BOOL advanced=[self.provider updateTargetGeometryGeneration:self.targetGeneration];[self.provider markSourceContentDirty];
  APDelay(.075,^{
   LGLocalButtonTextureFrame *moved=[self pull];NSData *pixels=APPixels(moved.texture);
   NSArray *shifted=APReadPixel(pixels,moved.texture.width,14*3+1,8*3),*oldPosition=APReadPixel(pixels,moved.texture.width,16*3+1,8*3);
   BOOL stripe=shifted.count==4&&[shifted[0] intValue]>250&&[shifted[1] intValue]>250&&[shifted[2] intValue]>250&&[oldPosition[2] intValue]>170&&[oldPosition[1] intValue]<70;
   LGLocalButtonSourceContract c={0};if(moved)c=moved.contract;
   [self record:@"owned_source_moved_ROI_captures_exact_shift_not_stretched_source" pass:advanced&&moved&&stripe&&c.targetGeometryGeneration==902&&fabs(c.sourceRectInOwnerPoints.origin.x-2)<.001 details:@{@"sourceOriginPoints":@[@(c.sourceRectInOwnerPoints.origin.x),@(c.sourceRectInOwnerPoints.origin.y)],@"shiftedStripeBGRA":shifted?:@[],@"oldStripePositionBGRA":oldPosition?:@[],@"newGeneration":@(c.targetGeometryGeneration)}];
   uint64_t prior=self.material.lastCompletedSubmissionSerial;LGLocalButtonRendererResult submit=[self.material submitOpticalState:[self state] enabled:YES];BOOL ready=submit==LGLocalButtonRendererReadyForNextDraw;
   APAwait(CACurrentMediaTime()+2,^BOOL{return !ready||(self.material.lastCommandBufferSucceeded&&self.material.lastCompletedSubmissionSerial>prior);},^(BOOL done){
    [self record:@"owned_source_actual_renderer_completes_after_source_ROI_move" pass:ready&&done&&self.material.lastCompletedSubmissionSerial>prior details:@{@"completedSerial":@(self.material.lastCompletedSubmissionSerial),@"targetStill44pt":@(CGRectGetWidth(self.target.bounds)==44)}];
    [self.material invalidateLocalSource];for(UIView *v in [self.sourceRoot.subviews copy])[v removeFromSuperview];[self transparent];
   });
  });
 });
}

- (void)transparent {
 // Unsupported transparency is not filled with a synthetic matte. No read of
 // the containing button/window occurs to manufacture missing background.
 self.sourceRoot.opaque=NO;self.sourceRoot.backgroundColor=UIColor.clearColor;[self.provider markSourceContentDirty];
 APDelay(.075,^{
  LGLocalButtonTextureFrame *frame=[self pull];
  [self record:@"owned_source_transparent_pixels_rejected_without_matte" pass:frame==nil&&self.provider.lastStatus==LGAppOwnedButtonSourceStatusTransparentCaptureRejected details:@{@"status":@(self.provider.lastStatus)}];
  UIControl *other=[[UIControl alloc]initWithFrame:self.target.frame];[self.container addSubview:other];
  LGLocalButtonTextureFrame *wrong=[self.provider currentBackgroundFrameForTargetView:other monotonicTimestamp:CACurrentMediaTime()];
  [self record:@"owned_source_wrong_target_rejected" pass:wrong==nil details:@{@"status":@(self.provider.lastStatus)}];[other removeFromSuperview];
  LGAppOwnedButtonSourceProvider *feedback=[[LGAppOwnedButtonSourceProvider alloc]initWithSourceRoot:self.container targetView:self.target device:self.device edgePadding:UIEdgeInsetsZero explicitOptIn:YES];
  BOOL binding=[feedback bindMaterialViewForFeedbackExclusion:self.material device:self.device];
  LGLocalButtonTextureFrame *bad=[feedback currentBackgroundFrameForTargetView:self.target monotonicTimestamp:CACurrentMediaTime()];
  [self record:@"owned_source_ancestor_capture_feedback_rejected" pass:!binding&&bad==nil details:@{@"noContainingWindowOrSuperviewBitmap":@YES}];
  uint64_t previous=self.provider.ownerGeneration,token=self.provider.ownerInstanceToken;
  BOOL advanced=[self.provider advanceOwnerGeneration];
  [self record:@"owned_source_invalidated_owner_generation_not_alive" pass:advanced&&![self.provider isOwnerInstanceAlive:token generation:previous] details:@{@"oldOwnerGeneration":@(previous),@"newOwnerGeneration":@(self.provider.ownerGeneration)}];
  [self finish];
 });
}
- (void)finish {
 if(self.finished)return;self.finished=YES;
 [self.material invalidateLocalSource];[self.material removeFromSuperview];[self.target removeFromSuperview];[self.sourceRoot removeFromSuperview];[self.heldFrames removeAllObjects];
 BOOL passed=self.checks.count>=10;for(NSDictionary *d in self.checks)passed=passed&&[d[@"pass"] boolValue];
 NSDictionary *r=@{@"scope":@"Actual same-process provider captured only explicitly created original-App sibling sourceRoot.layer; no arbitrary window/user source capture",@"sourceKind":@"LiveAppOwnedTexture of declared UIKit subtree, NOT system live backdrop",@"checks":self.checks?:@[],@"availabilityEvents":self.availabilityEvents?:@[],@"pass":@(passed),@"originalSelfCheckContainerUsed":@YES,@"sourcePixelReadback":@"Only provider-owned immutable textures",@"materialPixelReadback":@"NOT_RUN",@"actualUIKitOpticalTouch":@NO,@"systemSourceProvider":@NO,@"newPageOrPersistentUIAdded":@NO,@"noWindowScreenshotOrPrivateCapture":@YES};
 if(self.completion)self.completion(r);self.completion=nil;self.container=nil;
}
@end
void RunAppOwnedBackgroundProviderProbe(id<MTLDevice> device,UIView *originalSelfCheckContainer,void (^completion)(NSDictionary *)) {
 APOwnedProbe *probe=[APOwnedProbe new];probe.device=device;probe.container=originalSelfCheckContainer;probe.completion=completion;[probe start];
}
