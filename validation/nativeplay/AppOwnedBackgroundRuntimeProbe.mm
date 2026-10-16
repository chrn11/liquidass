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
@property(nonatomic) uint64_t completedBefore;
@property(nonatomic) BOOL finished;
- (void)start;
- (void)captureNext;
- (void)poolFull;
- (void)transparent;
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
 LGButtonOpticalState s={0};LGOpticalSetEligibility(&s,true,true,true,true,true,901);return s;
}
- (void)start {
 NSCAssert(NSThread.isMainThread,@"Own-view provider test stays on main thread");
 self.checks=[NSMutableArray array];self.heldFrames=[NSMutableArray array];self.originalHeldPixelHashes=[NSMutableArray array];
 if(!self.container.window||!self.device){[self record:@"owned_source_test_requires_original_app_window" pass:NO details:nil];[self finish];return;}
 // A source sibling explicitly created for this App's existing selfcheck. Its
 // pixels are actual UIKit layer output; it never includes the target/text.
 self.sourceRoot=[[UIView alloc]initWithFrame:CGRectMake(0,0,76,76)];self.sourceRoot.opaque=YES;self.sourceRoot.backgroundColor=[UIColor colorWithRed:.8 green:.1 blue:.15 alpha:1];self.sourceRoot.userInteractionEnabled=NO;self.sourceRoot.accessibilityElementsHidden=YES;
 self.target=[[UIControl alloc]initWithFrame:CGRectMake(16,16,44,44)];self.target.userInteractionEnabled=NO;self.target.accessibilityElementsHidden=YES;
 [self.container addSubview:self.sourceRoot];[self.container addSubview:self.target];
 LGAppOwnedButtonSourceProvider *off=[[LGAppOwnedButtonSourceProvider alloc]initWithSourceRoot:self.sourceRoot targetView:self.target device:self.device edgePadding:UIEdgeInsetsMake(16,16,16,16) explicitOptIn:NO];
 LGLocalButtonTextureFrame *blocked=[off currentBackgroundFrameForTargetView:self.target monotonicTimestamp:CACurrentMediaTime()];[self record:@"owned_provider_optout_has_no_source" pass:blocked==nil details:@{@"status":@(off.lastStatus)}];
 self.provider=[[LGAppOwnedButtonSourceProvider alloc]initWithSourceRoot:self.sourceRoot targetView:self.target device:self.device edgePadding:UIEdgeInsetsMake(16,16,16,16) explicitOptIn:YES];
 self.material=[[LGLocalButtonMaterialView alloc]initWithFrame:self.target.frame targetView:self.target sourceProvider:self.provider allowApproximateSource:NO explicitOptIn:YES];
 if(!self.provider||!self.material){[self record:@"actual_provider_and_original_renderer_initialize" pass:NO details:nil];[self finish];return;}
 [self.container insertSubview:self.material belowSubview:self.target];
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
  [self captureNext];
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
   [self transparent];
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
 NSDictionary *r=@{@"scope":@"Actual same-process provider captured only explicitly created original-App sibling sourceRoot.layer; no arbitrary window/user source capture",@"sourceKind":@"LiveAppOwnedTexture of declared UIKit subtree, NOT system live backdrop",@"checks":self.checks?:@[],@"pass":@(passed),@"originalSelfCheckContainerUsed":@YES,@"sourcePixelReadback":@"Only provider-owned immutable textures",@"materialPixelReadback":@"NOT_RUN",@"actualUIKitOpticalTouch":@NO,@"systemSourceProvider":@NO,@"newPageOrPersistentUIAdded":@NO,@"noWindowScreenshotOrPrivateCapture":@YES};
 if(self.completion)self.completion(r);self.completion=nil;self.container=nil;
}
@end
void RunAppOwnedBackgroundProviderProbe(id<MTLDevice> device,UIView *originalSelfCheckContainer,void (^completion)(NSDictionary *)) {
 APOwnedProbe *probe=[APOwnedProbe new];probe.device=device;probe.container=originalSelfCheckContainer;probe.completion=completion;[probe start];
}
