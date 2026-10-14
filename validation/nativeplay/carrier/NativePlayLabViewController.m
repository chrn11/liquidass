#include "NativePlayLabViewController.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#import <simd/simd.h>
#include "PlayMaterialShared.h"
#include "LGButtonMaterialCandidate.h"
#include "LGButtonOpticalState.h"
#include "LGButtonPressureRoute.h"
#include "LocalRendererRuntimeProbe.h"

// Byte-for-byte field order/types of production Tweak.mm::LGUniforms / MSL Uniforms.
typedef struct {
    simd_float2 resolution, outputResolution, screenResolution, cardOrigin, wallpaperResolution, lensOrigin;
    float radius, bezelWidth, glassThickness, refractionScale, refractiveIndex;
    simd_float2 wallpaperOrigin, samplingTransformX, samplingTransformY, samplingTransformOffset;
    float samplingOrientation, backdropZoom, shapeScale;
    simd_float2 shapeOrigin, shapeSize;
    float useGlyphMask, dispersionStrength, fresnelGlareStrength, borderWidthPixels;
    simd_float4 tintColor;
    float buttonCandidate, buttonCandidateMaxOffset;
    simd_float2 buttonCandidateCenter;
    float buttonCandidatePointScale, buttonCandidateCornerRadius, buttonCandidateRendererScale;
} LGFinalUniforms;
_Static_assert(sizeof(LGFinalUniforms)==208, "production Metal Uniforms ABI size drift");
_Static_assert(offsetof(LGFinalUniforms,wallpaperOrigin)==72, "Uniforms wallpaperOrigin offset drift");
_Static_assert(offsetof(LGFinalUniforms,tintColor)==160, "Uniforms tintColor offset drift");
_Static_assert(offsetof(LGFinalUniforms,buttonCandidateCenter)==184, "Uniforms candidateCenter offset drift");
_Static_assert(offsetof(LGFinalUniforms,buttonCandidateRendererScale)==200, "Uniforms rendererScale offset drift");
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    simd_float4 viewportPress; // drawable width, height, press, interactive
    simd_float4 touchBezel;    // logical x, y, bezel, thickness
    simd_float4 optics;        // IOR, blur, tint, glare
    simd_float4 effects;       // visibility, blur stage, refraction stage, tint stage
    simd_uint4 flags;          // highlight stage, debug UV, candidate B, reserved
} PlayUniforms;
_Static_assert(sizeof(PlayUniforms)==80, "PlayLens.metal uniform size drift");
_Static_assert(offsetof(PlayUniforms,viewportPress)==0, "uniform viewport offset drift");
_Static_assert(offsetof(PlayUniforms,touchBezel)==16, "uniform touch offset drift");
_Static_assert(offsetof(PlayUniforms,optics)==32, "uniform optics offset drift");
_Static_assert(offsetof(PlayUniforms,effects)==48, "uniform effects offset drift");
_Static_assert(offsetof(PlayUniforms,flags)==64, "uniform flags offset drift");

static const NSUInteger kInputWidth=(NSUInteger)PLAY_INPUT_WIDTH, kInputHeight=(NSUInteger)PLAY_INPUT_HEIGHT, kMaxDrawableDimension=1024;
static const NSUInteger kFramesInFlight=3, kUniformStride=256;
static const float kBezel=18.0f, kThickness=10.0f, kIOR=1.5f, kBlur=.5f, kTint=0.0f, kGlare=.65f;
static NSString *const kInputName=@"InputBotanical.png";
static inline float PlaySDF(float x,float y) { float qx=fabsf(x-PLAY_CENTER_X)-PLAY_CAPSULE_HALF_WIDTH+PLAY_CAPSULE_RADIUS, qy=fabsf(y-PLAY_CENTER_Y)-PLAY_CAPSULE_HALF_HEIGHT+PLAY_CAPSULE_RADIUS; return hypotf(fmaxf(qx,0),fmaxf(qy,0))+fminf(fmaxf(qx,qy),0)-PLAY_CAPSULE_RADIUS; }
static inline float PlaySmoothstep(float a,float b,float x) { float t=fminf(fmaxf((x-a)/(b-a),0.0f),1.0f); return t*t*(3.0f-2.0f*t); }
// Independent idle CPU mirror of the bounded one-entry Snell/projection UV path.
static void PlayExpectedIdleOpticalOffset(float x,float y,float *outX,float *outY) {
    const float regularizer=PLAY_DOME_REGULARIZER, domeRadius=PLAY_DOME_RADIUS, axialRadius=PLAY_AXIAL_RADIUS;
    float lx=x-PLAY_CENTER_X, ly=y-PLAY_CENTER_Y;
    float rx=lx-fminf(fmaxf(lx,-PLAY_DOME_STRAIGHT_HALF),PLAY_DOME_STRAIGHT_HALF), ry=ly;
    float r2=rx*rx+ry*ry, q=fminf(fmaxf(1.0f-r2/(domeRadius*domeRadius),0.0f),1.0f);
    float denominator=sqrtf(1.0f+regularizer*regularizer)-regularizer;
    float root=sqrtf(q+regularizer*regularizer), amplitude=fminf(PLAY_HEIGHT_MAX_PX,kBezel*PLAY_HEIGHT_BEZEL_GAIN+kThickness*PLAY_HEIGHT_THICKNESS_GAIN);
    float baseHeight=amplitude*(root-regularizer)/denominator;
    float baseSlopeX=amplitude*rx/(domeRadius*domeRadius*denominator*root);
    float baseSlopeY=amplitude*ry/(domeRadius*domeRadius*denominator*root);
    float aq=fminf(fmaxf(1.0f-(lx/axialRadius)*(lx/axialRadius),0.0f),1.0f);
    float axialRoot=sqrtf(aq+regularizer*regularizer);
    float axial=(axialRoot-regularizer)/denominator;
    float axialTilt=lx/(axialRadius*axialRadius*axialRoot*denominator);
    float height=baseHeight*axial;
    float slopeX=axial*baseSlopeX+baseHeight*axialTilt, slopeY=axial*baseSlopeY;
    float transportScale=fminf(fmaxf(kThickness/10.0f,0.0f),1.6f)*PLAY_TRANSPORT_SLOPE_SCALE;
    float nl=sqrtf((slopeX*transportScale)*(slopeX*transportScale)+(slopeY*transportScale)*(slopeY*transportScale)+1.0f);
    float nx=slopeX*transportScale/nl, ny=slopeY*transportScale/nl, nz=1.0f/nl, eta=1.0f/kIOR;
    float dotNI=-nz, discriminant=1.0f-eta*eta*(1.0f-dotNI*dotNI);
    float coefficient=eta*dotNI+sqrtf(fmaxf(discriminant,0.0f));
    float rayX=-coefficient*nx, rayY=-coefficient*ny, rayZ=-eta-coefficient*nz;
    float path=PlaySmoothstep(0.0f,PLAY_PATH_FADE_HEIGHT_PX,fmaxf(height,0.0f));
    float projectionDepth=(kThickness+fmaxf(height,0.0f)+PLAY_VIRTUAL_IMAGE_GAP_PX)*path;
    float ox=rayX/fmaxf(-rayZ,.25f)*projectionDepth, oy=rayY/fmaxf(-rayZ,.25f)*projectionDepth;
    float magnitude=hypotf(ox,oy), bound=sqrtf(1.0f+magnitude*magnitude/(PLAY_REFRACTION_LIMIT_PX*PLAY_REFRACTION_LIMIT_PX));
    ox/=bound; oy/=bound;
    float halfTexel=.5f;
    *outX=fminf(fmaxf(x+ox,halfTexel),PLAY_INPUT_WIDTH-halfTexel)-x;
    *outY=fminf(fmaxf(y+oy,halfTexel),PLAY_INPUT_HEIGHT-halfTexel)-y;
}
static inline double PlaySRGBDecodeByte(uint8_t value) { double c=(double)value/255.0; return c<=.04045?c/12.92:pow((c+.055)/1.055,2.4); }
static BOOL PlayTouchSetContainsIdentity(NSSet<UITouch *> *touches, UITouch *tracked) { for (UITouch *candidate in touches) if (candidate==tracked) return YES; return NO; }

@class NativePlayLabViewController;
@interface PlayPane : MTKView
@property(nonatomic,weak) NativePlayLabViewController *owner;
@property(nonatomic) NSInteger role;
@property(nonatomic,strong) UITouch *trackedTouch;
- (void)clearTrackedTouch;
@end
@interface NativePlayLabViewController (PlayTouchHandling)
- (BOOL)beginTouchInPane:(PlayPane *)pane touch:(UITouch *)touch atPoint:(CGPoint)point;
- (void)moveTouchInPane:(PlayPane *)pane touch:(UITouch *)touch toPoint:(CGPoint)point;
- (void)endTouchInPane:(PlayPane *)pane touch:(UITouch *)touch cancelled:(BOOL)cancelled;
- (BOOL)ownsTouch:(UITouch *)touch;
- (NSUInteger)traceSequenceForTouch:(UITouch *)touch create:(BOOL)create;
- (void)forgetTraceTouch:(UITouch *)touch;
- (void)recordUIKitTouch:(UITouch *)touch pane:(PlayPane *)pane phase:(NSString *)phase accepted:(BOOL)accepted cause:(NSString *)cause;
- (void)recordAppEvent:(NSString *)kind source:(NSString *)source details:(NSDictionary *)details;
- (void)cancelTouchOwnershipFromSource:(NSString *)source;
- (BOOL)writeInputTraceWithReason:(NSString *)reason;
@end
@implementation PlayPane
- (void)clearTrackedTouch { self.trackedTouch=nil; }
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (event.allTouches.count>1) {
        for (UITouch *touch in touches) [self.owner recordUIKitTouch:touch pane:self phase:@"began" accepted:NO cause:@"multipleTouchesPolicy"];
        [self.owner cancelTouchOwnershipFromSource:@"controller.multiTouchPolicy"];
        return;
    }
    UITouch *touch=touches.anyObject;
    if (self.trackedTouch) {
        if (touch) [self.owner recordUIKitTouch:touch pane:self phase:@"began" accepted:NO cause:@"paneAlreadyTracksTouch"];
        return;
    }
    if (self.role==1 && touches.count==1) {
        BOOL accepted=[self.owner beginTouchInPane:self touch:touch atPoint:[touch locationInView:self]];
        if (accepted) self.trackedTouch=touch;
        [self.owner recordUIKitTouch:touch pane:self phase:@"began" accepted:accepted cause:nil];
        if (accepted) return;
    } else {
        for (UITouch *candidate in touches) [self.owner recordUIKitTouch:candidate pane:self phase:@"began" accepted:NO cause:@"notInteractivePlayPane"];
    }
    [super touchesBegan:touches withEvent:event];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (event.allTouches.count>1) {
        for (UITouch *touch in touches) [self.owner recordUIKitTouch:touch pane:self phase:@"moved" accepted:(touch==self.trackedTouch && [self.owner ownsTouch:touch]) cause:@"multipleTouchesPolicy"];
        [self.owner cancelTouchOwnershipFromSource:@"controller.multiTouchPolicy"];
        return;
    }
    UITouch *touch=self.trackedTouch;
    if (!touch) {
        for (UITouch *candidate in touches) [self.owner recordUIKitTouch:candidate pane:self phase:@"moved" accepted:NO cause:@"noTrackedTouch"];
        [super touchesMoved:touches withEvent:event]; return;
    }
    if (PlayTouchSetContainsIdentity(touches,touch)) {
        [self.owner moveTouchInPane:self touch:touch toPoint:[touch locationInView:self]];
        [self.owner recordUIKitTouch:touch pane:self phase:@"moved" accepted:([self.owner ownsTouch:touch]) cause:nil];
    } else {
        for (UITouch *candidate in touches) [self.owner recordUIKitTouch:candidate pane:self phase:@"moved" accepted:NO cause:@"differentTouchIdentity"];
    }
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (event.allTouches.count>1) {
        for (UITouch *touch in touches) [self.owner recordUIKitTouch:touch pane:self phase:@"ended" accepted:(touch==self.trackedTouch && [self.owner ownsTouch:touch]) cause:@"multipleTouchesPolicy"];
        [self.owner cancelTouchOwnershipFromSource:@"controller.multiTouchPolicy"];
        return;
    }
    UITouch *touch=self.trackedTouch;
    if (touch && PlayTouchSetContainsIdentity(touches,touch)) {
        BOOL accepted=([self.owner ownsTouch:touch]);
        [self.owner endTouchInPane:self touch:touch cancelled:NO];
        [self.owner recordUIKitTouch:touch pane:self phase:@"ended" accepted:accepted cause:nil];
        [self.owner forgetTraceTouch:touch];
        [self.owner writeInputTraceWithReason:@"UIKit touchesEnded; release is recorded and recovery continues by display link"];
        return;
    }
    for (UITouch *candidate in touches) [self.owner recordUIKitTouch:candidate pane:self phase:@"ended" accepted:NO cause:@"differentTouchIdentity"];
    [super touchesEnded:touches withEvent:event];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UIScrollView *scroll=nil; UIView *ancestor=self.superview;
    while (ancestor && ![ancestor isKindOfClass:UIScrollView.class]) ancestor=ancestor.superview;
    if ([ancestor isKindOfClass:UIScrollView.class]) scroll=(UIScrollView *)ancestor;
    UIGestureRecognizerState panState=scroll.panGestureRecognizer.state;
    BOOL scrollPanRecognized=(panState==UIGestureRecognizerStateBegan || panState==UIGestureRecognizerStateChanged);
    NSString *cause=scrollPanRecognized?@"scrollViewPanRecognized":@"UIKitCancellationOriginNotConfirmed";
    for (UITouch *candidate in touches) [self.owner recordUIKitTouch:candidate pane:self phase:@"cancelled" accepted:(candidate==self.trackedTouch && [self.owner ownsTouch:candidate]) cause:cause];
    if (event.allTouches.count>1) {
        [self.owner cancelTouchOwnershipFromSource:@"controller.multiTouchPolicy"];
        for (UITouch *candidate in touches) [self.owner forgetTraceTouch:candidate];
        [self.owner writeInputTraceWithReason:@"UIKit touchesCancelled during multiple-touch policy"];
        return;
    }
    UITouch *touch=self.trackedTouch;
    if (touch && PlayTouchSetContainsIdentity(touches,touch)) {
        [self.owner endTouchInPane:self touch:touch cancelled:YES];
        [self.owner forgetTraceTouch:touch];
        [self.owner writeInputTraceWithReason:@"UIKit touchesCancelled"];
        return;
    }
    for (UITouch *candidate in touches) [self.owner forgetTraceTouch:candidate];
    [super touchesCancelled:touches withEvent:event];
}
@end

@interface LiveInputSlot : NSObject
@property(nonatomic,strong) id<MTLTexture> texture;
@property(nonatomic,strong) NSMutableData *pixels;
@property(nonatomic) NSUInteger inFlightUses;
@property(nonatomic) uint64_t generation;
@property(nonatomic) CGPoint contentOffset;
@property(nonatomic) CGRect viewportRect;
@property(nonatomic) CGSize scaleTo480x360;
@property(nonatomic,copy) NSString *sha256;
@end
@implementation LiveInputSlot @end

@interface LiveSceneContentView : UIView
@end
@implementation LiveSceneContentView
- (void)drawRect:(CGRect)rect {
    (void)rect;
    [[UIColor colorWithRed:.055 green:.075 blue:.10 alpha:1] setFill]; UIRectFill(self.bounds);
    NSArray<UIColor *> *colors=@[[UIColor colorWithRed:.10 green:.42 blue:.38 alpha:1],[UIColor colorWithRed:.42 green:.27 blue:.55 alpha:1],[UIColor colorWithRed:.75 green:.35 blue:.18 alpha:1],[UIColor colorWithRed:.16 green:.38 blue:.66 alpha:1],[UIColor colorWithRed:.58 green:.43 blue:.12 alpha:1]];
    NSArray<NSString *> *names=@[@"LIVE CONTENT · NORTH",@"LIVE CONTENT · CANOPY",@"LIVE CONTENT · STUDIO",@"LIVE CONTENT · WATER",@"LIVE CONTENT · DUSK"];
    UIFont *head=[UIFont systemFontOfSize:18 weight:UIFontWeightBold], *body=[UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    NSDictionary *ha=@{NSFontAttributeName:head,NSForegroundColorAttributeName:UIColor.whiteColor};
    NSDictionary *ba=@{NSFontAttributeName:body,NSForegroundColorAttributeName:[UIColor colorWithWhite:.94 alpha:1]};
    for(NSUInteger i=0;i<names.count;i++) {
        CGFloat y=16+(CGFloat)i*228, w=MAX(120,self.bounds.size.width-24);
        CGRect card=CGRectMake(12,y,w,210); UIBezierPath *path=[UIBezierPath bezierPathWithRoundedRect:card cornerRadius:18]; [colors[i] setFill]; [path fill];
        [names[i] drawAtPoint:CGPointMake(card.origin.x+16,card.origin.y+16) withAttributes:ha];
        NSString *detail=[NSString stringWithFormat:@"offset panel %lu · UIKit-owned text + color blocks",(unsigned long)(i+1)]; [detail drawAtPoint:CGPointMake(card.origin.x+16,card.origin.y+46) withAttributes:ba];
        CGFloat tileY=card.origin.y+88, tileW=(w-40)/3.0;
        for(NSUInteger j=0;j<3;j++) { UIColor *tile=[UIColor colorWithRed:.15+.22*j green:.27+.12*i blue:.68-.12*j alpha:1]; CGRect r=CGRectMake(card.origin.x+16+j*(tileW+4),tileY,tileW,88); UIBezierPath *tp=[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:9]; [tile setFill]; [tp fill]; NSString *label=[NSString stringWithFormat:@"BLOCK %lu",(unsigned long)(j+1)]; [label drawAtPoint:CGPointMake(r.origin.x+8,r.origin.y+34) withAttributes:ba]; }
    }
}
@end

@interface PlayLabFrame : UIView
@property(nonatomic,strong) UIImageView *sourceView;
@property(nonatomic,strong) PlayPane *metalView;
@property(nonatomic,strong) UILabel *playLabel;
@property(nonatomic,strong) UILabel *heading;
@end
@implementation PlayLabFrame @end

@interface NativePlayLabViewController () <UIScrollViewDelegate>
@property(nonatomic,strong) UIImage *sourceImage;
@property(nonatomic,strong) id<MTLDevice> device;
@property(nonatomic,strong) id<MTLCommandQueue> queue;
@property(nonatomic,strong) id<MTLTexture> inputTexture;
@property(nonatomic,strong) id<MTLSamplerState> sampler;
@property(nonatomic,strong) id<MTLRenderPipelineState> pipeline;
@property(nonatomic,strong) NSMutableArray<id<MTLBuffer>> *uniformRing;
@property(nonatomic) dispatch_semaphore_t inflight;
@property(nonatomic) NSUInteger frameIndex;
@property(nonatomic,strong) PlayLabFrame *frameA;
@property(nonatomic,strong) PlayLabFrame *frameB;
@property(nonatomic,strong) UIScrollView *inputScrollView;
@property(nonatomic,strong) UIView *liveSceneHost;
@property(nonatomic,strong) UIScrollView *liveSceneScroll;
@property(nonatomic,strong) LiveSceneContentView *liveSceneContent;
@property(nonatomic,strong) UIButton *liveSceneModeButton;
@property(nonatomic,strong) UIButton *liveSceneTestButton;
@property(nonatomic,strong) NSMutableArray<LiveInputSlot *> *liveInputSlots;
@property(nonatomic,strong) LiveInputSlot *liveCurrentSlot;
@property(nonatomic) NSUInteger liveNextSlotIndex;
@property(nonatomic) uint64_t liveGeneration;
@property(nonatomic) NSUInteger liveUserScrollCount;
@property(nonatomic) BOOL liveSceneMode;
@property(nonatomic) BOOL liveCaptureInvalidated;
@property(nonatomic) BOOL liveTestOffsetActive;
@property(nonatomic) BOOL liveUserScrollObserved;
@property(nonatomic) CFTimeInterval liveLastCaptureTime;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UILabel *provenanceLabel;
@property(nonatomic,strong) UIButton *testButton;
@property(nonatomic,strong) UILabel *traceStatusLabel;
@property(nonatomic,strong) UIButton *traceExportButton;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *inputTraceEvents;
@property(nonatomic,strong) NSMapTable<UITouch *, NSNumber *> *touchSequenceMap;
@property(nonatomic,copy) NSString *inputTraceSessionID;
@property(nonatomic,copy) NSString *lastInputTraceFile;
@property(nonatomic) CFTimeInterval inputTraceSessionStart;
@property(nonatomic) NSUInteger inputTraceEventOrder;
@property(nonatomic) NSUInteger nextTouchSequence;
@property(nonatomic) NSUInteger framesActuallySubmitted;
@property(nonatomic) NSUInteger framesCompleted;
@property(nonatomic) NSUInteger droppedTraceEvents;
@property(nonatomic) float maxPressActuallySubmitted;
@property(nonatomic) float maxPressInCompletedCommandBuffer;
@property(nonatomic) BOOL inputTraceWasTruncated;
@property(nonatomic) BOOL awaitingReleaseRecovery;
@property(nonatomic) BOOL pressSubmissionLogged;
@property(nonatomic) BOOL pressCompletionLogged;
@property(nonatomic) BOOL releaseSubmissionLogged;
@property(nonatomic) BOOL releaseCompletionLogged;
@property(nonatomic,strong) CADisplayLink *displayLink;
@property(nonatomic,strong) UITouch *activeTouch;
@property(nonatomic) BOOL appActive;
@property(nonatomic) BOOL metalReady;
@property(nonatomic) BOOL testRunning;
@property(nonatomic) BOOL pointerActive;
@property(nonatomic) float press;
@property(nonatomic) float velocity;
@property(nonatomic) float target;
@property(nonatomic) float touchX;
@property(nonatomic) float touchY;
@property(nonatomic) CFTimeInterval previousTime;
@property(nonatomic,strong) NSDictionary *manifest;
@property(nonatomic,copy) NSString *inputSHA256;
@property(nonatomic,copy) NSString *sourceSHA256;
@property(nonatomic,copy) NSString *nativeShaderSHA256;
@property(nonatomic,copy) NSString *nativeControllerSHA256;
@property(nonatomic,copy) NSString *nativeMaterialSharedSHA256;
@property(nonatomic,copy) NSString *manifestSHA256;
@end

@implementation NativePlayLabViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=NSLocalizedString(@"Native Play25 Lab",nil);
    self.view.backgroundColor=[UIColor colorWithWhite:.055 alpha:1];
    self.appActive=(UIApplication.sharedApplication.applicationState==UIApplicationStateActive); self.touchX=240; self.touchY=180;
    self.inputTraceSessionID=NSUUID.UUID.UUIDString; self.inputTraceSessionStart=CACurrentMediaTime(); self.inputTraceEvents=[NSMutableArray arrayWithCapacity:128]; self.touchSequenceMap=[NSMapTable weakToStrongObjectsMapTable]; self.nextTouchSequence=1;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(appWillResign:) name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(appDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(appDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [self loadProvenance];
    [self buildInterface];
    [self loadInput];
    if (!self.sourceImage) { [self fail:@"InputBotanical.png missing/invalid; Metal preview and GPU check unavailable."]; return; }
    self.device=MTLCreateSystemDefaultDevice();
    if (!self.device) { [self fail:@"Metal device unavailable. Showing bundled input only; no fake GPU preview."]; return; }
    self.queue=[self.device newCommandQueue];
    if (!self.queue) { [self fail:@"Metal command queue creation failed. Showing bundled input only."]; return; }
    [self installMetalViews];
    [self loadInputTexture];
    if (!self.inputTexture) { [self fail:@"Input texture creation failed. Showing bundled input only."]; return; }
    [self createPipeline];
    if (!self.pipeline) return;
    self.inflight=dispatch_semaphore_create((long)kFramesInFlight);
    self.uniformRing=[NSMutableArray arrayWithCapacity:kFramesInFlight];
    for (NSUInteger i=0;i<kFramesInFlight;i++) {
        id<MTLBuffer> buffer=[self.device newBufferWithLength:kUniformStride*2 options:MTLResourceStorageModeShared];
        if (!buffer) { [self fail:@"Bounded uniform ring allocation failed."]; return; }
        [self.uniformRing addObject:buffer];
    }
    self.metalReady=YES;
    self.frameA.metalView.hidden=NO; self.frameB.metalView.hidden=NO;
    [self setStatus:@"Metal pipeline ready · GPU self-check is explicit; not run automatically."];
    [self drawFrameNow];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [self stopFrames]; }

- (NSString *)traceApplicationState {
    switch (UIApplication.sharedApplication.applicationState) {
        case UIApplicationStateActive: return @"active";
        case UIApplicationStateInactive: return @"inactive";
        case UIApplicationStateBackground: return @"background";
        default: return @"unknown";
    }
}
- (NSUInteger)traceSequenceForTouch:(UITouch *)touch create:(BOOL)create {
    if (!touch) return 0;
    NSNumber *number=[self.touchSequenceMap objectForKey:touch];
    if (!number && create) { number=@(self.nextTouchSequence++); [self.touchSequenceMap setObject:number forKey:touch]; }
    return number.unsignedIntegerValue;
}
- (void)forgetTraceTouch:(UITouch *)touch { if (touch) [self.touchSequenceMap removeObjectForKey:touch]; }
- (BOOL)ownsTouch:(UITouch *)touch { return touch && touch==self.activeTouch && self.pointerActive; }
- (void)appendInputTraceEvent:(NSMutableDictionary *)event {
    event[@"order"]=@(++self.inputTraceEventOrder);
    event[@"wallTimeUnixSeconds"]=@([NSDate date].timeIntervalSince1970);
    event[@"sessionElapsedSeconds"]=@(MAX(0,CACurrentMediaTime()-self.inputTraceSessionStart));
    [self.inputTraceEvents addObject:[event copy]];
    if (self.inputTraceEvents.count>128) { [self.inputTraceEvents removeObjectAtIndex:0]; self.inputTraceWasTruncated=YES; self.droppedTraceEvents++; }
    [self refreshInputTraceStatus];
}
- (void)recordUIKitTouch:(UITouch *)touch pane:(PlayPane *)pane phase:(NSString *)phase accepted:(BOOL)accepted cause:(NSString *)cause {
    NSUInteger sequence=[self traceSequenceForTouch:touch create:[phase isEqualToString:@"began"]];
    CGPoint p=touch?[touch locationInView:pane]:CGPointZero; CGFloat w=pane.bounds.size.width,h=pane.bounds.size.height;
    NSMutableDictionary *event=[@{@"kind":@"UIKit.touch",@"source":[NSString stringWithFormat:@"UIKit.touches%@",phase.capitalizedString],@"phase":phase,@"touchSequence":@(sequence),@"accepted":@(accepted),@"owned":@([self ownsTouch:touch]),@"press":@(self.press),@"target":@(self.target),@"applicationState":[self traceApplicationState],@"gpuSelfCheckActive":@(self.testRunning),@"pane":pane.role==1?@"B":@"A"} mutableCopy];
    if (w>0 && h>0) event[@"renderPoint480x360"]=@{@"x":@(p.x/w*kInputWidth),@"y":@(p.y/h*kInputHeight)};
    if (cause.length) event[@"cause"]=cause;
    [self appendInputTraceEvent:event];
}
- (void)recordAppEvent:(NSString *)kind source:(NSString *)source details:(NSDictionary *)details {
    NSUInteger activeSequence=[self traceSequenceForTouch:self.activeTouch create:NO];
    NSMutableDictionary *event=[@{@"kind":kind?:@"appEvent",@"source":source?:@"app.internal",@"accepted":[NSNull null],@"owned":@(self.pointerActive && self.activeTouch!=nil),@"touchSequence":@(activeSequence),@"press":@(self.press),@"target":@(self.target),@"applicationState":[self traceApplicationState],@"gpuSelfCheckActive":@(self.testRunning)} mutableCopy];
    if (details) [event addEntriesFromDictionary:details];
    [self appendInputTraceEvent:event];
}
- (void)refreshInputTraceStatus {
    if (!self.traceStatusLabel) return;
    NSString *truncated=self.inputTraceWasTruncated?@" · TRUNCATED":@"";
    NSString *owner=(self.pointerActive && self.activeTouch)?@"owned":@"released";
    NSString *saved=self.lastInputTraceFile.length?[NSString stringWithFormat:@" · %@",self.lastInputTraceFile]:@"";
    NSString *text=[NSString stringWithFormat:@"UIKit trace %@ · %lu/128%@\n%@ · target %.2f · press %.2f · submitted %lu/completed %lu%@",[self.inputTraceSessionID substringToIndex:MIN(8,self.inputTraceSessionID.length)],(unsigned long)self.inputTraceEvents.count,truncated,owner,self.target,self.press,(unsigned long)self.framesActuallySubmitted,(unsigned long)self.framesCompleted,saved];
    self.traceStatusLabel.text=text; self.traceStatusLabel.accessibilityValue=text;
}
- (BOOL)writeInputTraceWithReason:(NSString *)reason {
    if (!self.inputTraceEvents) return NO;
    NSDictionary *info=NSBundle.mainBundle.infoDictionary;
    NSDictionary *trace=@{@"schemaVersion":@1,@"scope":@"App-owned bounded lifecycle trace. UIKit events are logged only from actual PlayPane touch callbacks; UIApplication events only from registered notifications. Controller resets and render observations use distinct source labels. No pointer addresses or system data are exported.",@"sessionUUID":self.inputTraceSessionID?:@"unavailable",@"writtenAtUnixSeconds":@([NSDate date].timeIntervalSince1970),@"writeReason":reason?:@"unspecified",@"app":@{@"bundleIdentifier":info[@"CFBundleIdentifier"]?:@"unavailable",@"shortVersion":info[@"CFBundleShortVersionString"]?:@"unavailable",@"buildVersion":info[@"CFBundleVersion"]?:@"unavailable"},@"sourceHashes":@{@"nativePlayLensSHA256":self.nativeShaderSHA256?:@"unavailable",@"nativeControllerSHA256":self.nativeControllerSHA256?:@"unavailable",@"nativeMaterialSharedSHA256":self.nativeMaterialSharedSHA256?:@"unavailable",@"inputBotanicalSHA256":self.inputSHA256?:@"unavailable",@"webOpticalSHA256":self.sourceSHA256?:@"unavailable",@"manifestSourceSHA256":self.manifestSHA256?:@"unavailable"},@"eventBuffer":@{@"capacity":@128,@"retainedCount":@(self.inputTraceEvents.count),@"truncated":@(self.inputTraceWasTruncated),@"droppedCount":@(self.droppedTraceEvents),@"totalEventsSeen":@(self.inputTraceEventOrder)},@"liveDrawableFrames":@{@"submittedCount":@(self.framesActuallySubmitted),@"completedCount":@(self.framesCompleted),@"maximumPressActuallySubmitted":@(self.maxPressActuallySubmitted),@"maximumPressInCompletedCommandBuffer":@(self.maxPressInCompletedCommandBuffer),@"currentPress":@(self.press),@"currentTarget":@(self.target),@"ownedAtExport":@(self.pointerActive && self.activeTouch!=nil),@"measurementNote":@"press values are B drawable uniforms in submitted/completed live Metal command buffers; not a visual or touch-source substitute"},@"applicationStateAtExport":[self traceApplicationState],@"events":[self.inputTraceEvents copy]};
    NSError *serializationError=nil; NSData *json=[NSJSONSerialization dataWithJSONObject:trace options:NSJSONWritingPrettyPrinted error:&serializationError];
    if (!json) { [self recordAppEvent:@"inputTraceSerializationFailed" source:@"app.JSONSerialization" details:@{@"error":serializationError.localizedDescription?:@"unknown"}]; return NO; }
    NSString *name=[NSString stringWithFormat:@"native-inputtrace-%@.json",self.inputTraceSessionID?:NSUUID.UUID.UUIDString]; NSError *writeError=nil;
    BOOL written=[json writeToURL:[[self documentsURL] URLByAppendingPathComponent:name] options:NSDataWritingAtomic error:&writeError];
    if (written) self.lastInputTraceFile=name;
    else self.lastInputTraceFile=[NSString stringWithFormat:@"trace write FAILED: %@",writeError.localizedDescription?:@"unknown"];
    [self refreshInputTraceStatus]; return written;
}
- (void)exportInputTraceFromButton { [self writeInputTraceWithReason:@"explicit export button action (UIKit UIControlEventTouchUpInside)"]; }

- (void)loadProvenance {
    NSURL *url=[[NSBundle mainBundle] URLForResource:@"manifest" withExtension:@"json"];
    NSData *data=url?[NSData dataWithContentsOfURL:url]:nil;
    if (data) self.manifest=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *resources=self.manifest[@"resources"];
    self.inputSHA256=resources[@"InputBotanical.png"] ?: @"unavailable";
    NSDictionary *source=self.manifest[@"source"];
    self.sourceSHA256=source[@"webOpticalSHA256"] ?: @"unavailable";
    self.nativeShaderSHA256=source[@"nativePlayLensSHA256"] ?: @"unavailable";
    self.nativeControllerSHA256=source[@"nativeControllerSHA256"] ?: @"unavailable";
    self.nativeMaterialSharedSHA256=source[@"nativeMaterialSharedSHA256"] ?: @"unavailable";
    self.manifestSHA256=resources[@"manifestSourceSHA256"] ?: @"unavailable";
}

- (void)buildInterface {
    UIScrollView *scroll=[UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints=NO; scroll.scrollEnabled=YES; scroll.alwaysBounceVertical=NO; scroll.delaysContentTouches=YES; scroll.canCancelContentTouches=YES; scroll.directionalLockEnabled=YES; scroll.delegate=self; self.inputScrollView=scroll; [self.view addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[[scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4],[scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],[scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]]];
    UIStackView *stack=[UIStackView new]; stack.axis=UILayoutConstraintAxisVertical; stack.spacing=8; stack.translatesAutoresizingMaskIntoConstraints=NO; [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:6],[stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-8],[stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:14],[stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-14]]];
    UILabel *title=[UILabel new]; title.text=@"Play25 · isolated native Metal"; title.font=[UIFont systemFontOfSize:21 weight:UIFontWeightBold]; title.textColor=UIColor.whiteColor; title.numberOfLines=1; [stack addArrangedSubview:title];
    UILabel *subtitle=[UILabel new]; subtitle.text=@"A = same source, new-geometry neutral   ·   B = build11 272×144 lens"; subtitle.font=[UIFont systemFontOfSize:12 weight:UIFontWeightMedium]; subtitle.textColor=[UIColor colorWithWhite:.78 alpha:1]; subtitle.numberOfLines=2; [stack addArrangedSubview:subtitle];
    self.liveSceneModeButton=[UIButton buttonWithType:UIButtonTypeSystem]; self.liveSceneModeButton.translatesAutoresizingMaskIntoConstraints=NO; self.liveSceneModeButton.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]; [self.liveSceneModeButton setTitle:@"Scene: fixed-botanical · tap for App-owned live scene" forState:UIControlStateNormal]; [self.liveSceneModeButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal]; self.liveSceneModeButton.backgroundColor=[UIColor colorWithRed:.16 green:.25 blue:.31 alpha:1]; self.liveSceneModeButton.layer.cornerRadius=9; self.liveSceneModeButton.accessibilityIdentifier=@"toggleAppOwnedLiveSceneMode"; [self.liveSceneModeButton addTarget:self action:@selector(toggleLiveSceneMode) forControlEvents:UIControlEventTouchUpInside]; [stack addArrangedSubview:self.liveSceneModeButton]; [self.liveSceneModeButton.heightAnchor constraintEqualToConstant:40].active=YES;
    self.liveSceneHost=[UIView new]; self.liveSceneHost.translatesAutoresizingMaskIntoConstraints=NO; self.liveSceneHost.backgroundColor=[UIColor colorWithWhite:.08 alpha:1]; self.liveSceneHost.layer.cornerRadius=14; self.liveSceneHost.clipsToBounds=YES; self.liveSceneHost.hidden=YES; [stack addArrangedSubview:self.liveSceneHost]; [self.liveSceneHost.heightAnchor constraintEqualToAnchor:self.liveSceneHost.widthAnchor multiplier:.75].active=YES;
    self.liveSceneScroll=[UIScrollView new]; self.liveSceneScroll.translatesAutoresizingMaskIntoConstraints=NO; self.liveSceneScroll.scrollEnabled=YES; self.liveSceneScroll.alwaysBounceVertical=NO; self.liveSceneScroll.delaysContentTouches=YES; self.liveSceneScroll.canCancelContentTouches=YES; self.liveSceneScroll.directionalLockEnabled=YES; self.liveSceneScroll.showsVerticalScrollIndicator=YES; self.liveSceneScroll.delegate=self; self.liveSceneScroll.backgroundColor=[UIColor colorWithWhite:.06 alpha:1]; [self.liveSceneHost addSubview:self.liveSceneScroll];
    self.liveSceneContent=[LiveSceneContentView new]; self.liveSceneContent.translatesAutoresizingMaskIntoConstraints=NO; self.liveSceneContent.backgroundColor=[UIColor colorWithWhite:.06 alpha:1]; [self.liveSceneScroll addSubview:self.liveSceneContent];
    [NSLayoutConstraint activateConstraints:@[[self.liveSceneScroll.topAnchor constraintEqualToAnchor:self.liveSceneHost.topAnchor],[self.liveSceneScroll.bottomAnchor constraintEqualToAnchor:self.liveSceneHost.bottomAnchor],[self.liveSceneScroll.leadingAnchor constraintEqualToAnchor:self.liveSceneHost.leadingAnchor],[self.liveSceneScroll.trailingAnchor constraintEqualToAnchor:self.liveSceneHost.trailingAnchor],[self.liveSceneContent.topAnchor constraintEqualToAnchor:self.liveSceneScroll.contentLayoutGuide.topAnchor],[self.liveSceneContent.bottomAnchor constraintEqualToAnchor:self.liveSceneScroll.contentLayoutGuide.bottomAnchor],[self.liveSceneContent.leadingAnchor constraintEqualToAnchor:self.liveSceneScroll.contentLayoutGuide.leadingAnchor],[self.liveSceneContent.trailingAnchor constraintEqualToAnchor:self.liveSceneScroll.contentLayoutGuide.trailingAnchor],[self.liveSceneContent.widthAnchor constraintEqualToAnchor:self.liveSceneScroll.frameLayoutGuide.widthAnchor],[self.liveSceneContent.heightAnchor constraintEqualToAnchor:self.liveSceneScroll.frameLayoutGuide.widthAnchor multiplier:2.75]]];
    self.frameA=[self makeFrameWithHeading:@"A  ·  Input only"];
    self.frameB=[self makeFrameWithHeading:@"B  ·  Play capsule"];
    [stack addArrangedSubview:self.frameA]; [stack addArrangedSubview:self.frameB];
    [self.frameA.heightAnchor constraintEqualToAnchor:self.frameA.widthAnchor multiplier:.75].active=YES;
    [self.frameB.heightAnchor constraintEqualToAnchor:self.frameB.widthAnchor multiplier:.75].active=YES;
    self.testButton=[UIButton buttonWithType:UIButtonTypeSystem]; self.testButton.translatesAutoresizingMaskIntoConstraints=NO; self.testButton.titleLabel.font=[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]; [self.testButton setTitle:@"Run native GPU readback self-check" forState:UIControlStateNormal]; [self.testButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal]; self.testButton.backgroundColor=[UIColor colorWithRed:.17 green:.27 blue:.32 alpha:1]; self.testButton.layer.cornerRadius=10; self.testButton.accessibilityIdentifier=@"runNativeGPUReadbackSelfCheck"; [self.testButton addTarget:self action:@selector(runGPUReadbackCheck) forControlEvents:UIControlEventTouchUpInside]; [stack addArrangedSubview:self.testButton]; [self.testButton.heightAnchor constraintEqualToConstant:46].active=YES;
    self.liveSceneTestButton=[UIButton buttonWithType:UIButtonTypeSystem]; self.liveSceneTestButton.translatesAutoresizingMaskIntoConstraints=NO; self.liveSceneTestButton.titleLabel.font=[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]; [self.liveSceneTestButton setTitle:@"Export 3 App-owned live-scene offsets" forState:UIControlStateNormal]; [self.liveSceneTestButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal]; self.liveSceneTestButton.backgroundColor=[UIColor colorWithRed:.28 green:.24 blue:.16 alpha:1]; self.liveSceneTestButton.layer.cornerRadius=9; self.liveSceneTestButton.accessibilityIdentifier=@"exportAppOwnedLiveSceneAB"; [self.liveSceneTestButton addTarget:self action:@selector(runLiveSceneExport) forControlEvents:UIControlEventTouchUpInside]; [stack addArrangedSubview:self.liveSceneTestButton]; [self.liveSceneTestButton.heightAnchor constraintEqualToConstant:42].active=YES;
    self.statusLabel=[UILabel new]; self.statusLabel.textColor=[UIColor colorWithRed:.94 green:.80 blue:.48 alpha:1]; self.statusLabel.font=[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium]; self.statusLabel.numberOfLines=0; [stack addArrangedSubview:self.statusLabel];
    self.traceStatusLabel=[UILabel new]; self.traceStatusLabel.textColor=[UIColor colorWithRed:.47 green:.83 blue:.76 alpha:1]; self.traceStatusLabel.font=[UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightMedium]; self.traceStatusLabel.numberOfLines=2; self.traceStatusLabel.accessibilityIdentifier=@"nativeInputTraceStatus"; [stack addArrangedSubview:self.traceStatusLabel];
    self.traceExportButton=[UIButton buttonWithType:UIButtonTypeSystem]; self.traceExportButton.translatesAutoresizingMaskIntoConstraints=NO; self.traceExportButton.titleLabel.font=[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]; [self.traceExportButton setTitle:@"Export UIKit input trace JSON" forState:UIControlStateNormal]; [self.traceExportButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal]; self.traceExportButton.backgroundColor=[UIColor colorWithRed:.16 green:.29 blue:.28 alpha:1]; self.traceExportButton.layer.cornerRadius=9; self.traceExportButton.accessibilityIdentifier=@"exportNativeInputTrace"; [self.traceExportButton addTarget:self action:@selector(exportInputTraceFromButton) forControlEvents:UIControlEventTouchUpInside]; [stack addArrangedSubview:self.traceExportButton]; [self.traceExportButton.heightAnchor constraintEqualToConstant:42].active=YES;
    self.provenanceLabel=[UILabel new]; self.provenanceLabel.textColor=[UIColor colorWithWhite:.60 alpha:1]; self.provenanceLabel.font=[UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular]; self.provenanceLabel.numberOfLines=0; NSString *inputPrefix=[self.inputSHA256 substringToIndex:MIN(16,self.inputSHA256.length)]; NSString *shaderPrefix=[self.nativeShaderSHA256 substringToIndex:MIN(16,self.nativeShaderSHA256.length)]; NSString *webPrefix=[self.sourceSHA256 substringToIndex:MIN(16,self.sourceSHA256.length)]; self.provenanceLabel.text=[NSString stringWithFormat:@"input %@… · native MSL %@…\nfrozen Web baseline %@… · runtime compile",inputPrefix,shaderPrefix,webPrefix]; [stack addArrangedSubview:self.provenanceLabel];
    [self setStatus:@"Loading original botanical source…"];
    [self refreshInputTraceStatus];
}

- (PlayLabFrame *)makeFrameWithHeading:(NSString *)text {
    PlayLabFrame *frame=[PlayLabFrame new]; frame.translatesAutoresizingMaskIntoConstraints=NO; frame.clipsToBounds=YES; frame.layer.cornerRadius=15; frame.backgroundColor=[UIColor colorWithWhite:.10 alpha:1];
    frame.sourceView=[UIImageView new]; frame.sourceView.translatesAutoresizingMaskIntoConstraints=NO; frame.sourceView.contentMode=UIViewContentModeScaleAspectFit; frame.sourceView.clipsToBounds=YES; [frame addSubview:frame.sourceView];
    [NSLayoutConstraint activateConstraints:@[[frame.sourceView.topAnchor constraintEqualToAnchor:frame.topAnchor],[frame.sourceView.bottomAnchor constraintEqualToAnchor:frame.bottomAnchor],[frame.sourceView.leadingAnchor constraintEqualToAnchor:frame.leadingAnchor],[frame.sourceView.trailingAnchor constraintEqualToAnchor:frame.trailingAnchor]]];
    frame.heading=[UILabel new]; frame.heading.translatesAutoresizingMaskIntoConstraints=NO; frame.heading.text=text; frame.heading.font=[UIFont systemFontOfSize:12 weight:UIFontWeightBold]; frame.heading.textColor=[UIColor colorWithWhite:1 alpha:.92]; frame.heading.backgroundColor=[UIColor colorWithWhite:0 alpha:.42]; frame.heading.layer.cornerRadius=6; frame.heading.clipsToBounds=YES; [frame addSubview:frame.heading];
    [NSLayoutConstraint activateConstraints:@[[frame.heading.topAnchor constraintEqualToAnchor:frame.topAnchor constant:7],[frame.heading.leadingAnchor constraintEqualToAnchor:frame.leadingAnchor constant:8]]];
    return frame;
}

- (NSString *)sha256ForData:(NSData *)data {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes,(CC_LONG)data.length,digest); NSMutableString *out=[NSMutableString stringWithCapacity:64]; for(NSUInteger i=0;i<sizeof(digest);i++) [out appendFormat:@"%02x",digest[i]]; return out;
}
- (void)setupLiveInputSlots {
    if (self.liveInputSlots.count==3 || !self.device) return;
    self.liveInputSlots=[NSMutableArray arrayWithCapacity:3]; MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB width:kInputWidth height:kInputHeight mipmapped:NO]; d.usage=MTLTextureUsageShaderRead; d.storageMode=MTLStorageModeShared;
    for(NSUInteger i=0;i<3;i++) { LiveInputSlot *slot=[LiveInputSlot new]; slot.texture=[self.device newTextureWithDescriptor:d]; slot.pixels=[NSMutableData dataWithLength:kInputWidth*kInputHeight*4]; if(!slot.texture||!slot.pixels){ self.liveInputSlots=nil; return; } slot.texture.label=[NSString stringWithFormat:@"App-owned live input slot %lu",(unsigned long)i]; [self.liveInputSlots addObject:slot]; }
}
- (LiveInputSlot *)availableLiveInputSlot {
    if(self.liveInputSlots.count!=3) return nil;
    for(NSUInteger n=0;n<3;n++){NSUInteger i=(self.liveNextSlotIndex+n)%3; LiveInputSlot *slot=self.liveInputSlots[i]; if(slot.inFlightUses==0){self.liveNextSlotIndex=(i+1)%3;return slot;}}
    return nil;
}
- (BOOL)renderLiveSceneIntoSlot:(LiveInputSlot *)slot error:(NSError **)error {
    if(!slot||slot.inFlightUses||!self.liveSceneScroll||!self.liveSceneContent||CGRectIsEmpty(self.liveSceneScroll.bounds)){if(error)*error=[NSError errorWithDomain:@"NativePlayLab.LiveScene" code:1 userInfo:@{NSLocalizedDescriptionKey:@"No idle live-input slot or the owned viewport is not laid out."}];return NO;}
    [self.view layoutIfNeeded]; [self.liveSceneScroll layoutIfNeeded]; [self.liveSceneContent setNeedsDisplay]; [self.liveSceneContent.layer displayIfNeeded];
    CGFloat vw=self.liveSceneScroll.bounds.size.width,vh=self.liveSceneScroll.bounds.size.height; if(vw<=0||vh<=0){if(error)*error=[NSError errorWithDomain:@"NativePlayLab.LiveScene" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Owned UIScrollView has zero viewport size."}];return NO;}
    CGPoint offset=self.liveSceneScroll.contentOffset; CGFloat sx=(CGFloat)kInputWidth/vw,sy=(CGFloat)kInputHeight/vh; CGColorSpaceRef colorSpace=CGColorSpaceCreateDeviceRGB(); CGContextRef ctx=CGBitmapContextCreate(slot.pixels.mutableBytes,kInputWidth,kInputHeight,8,kInputWidth*4,colorSpace,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big); if(colorSpace)CGColorSpaceRelease(colorSpace);
    if(!ctx){if(error)*error=[NSError errorWithDomain:@"NativePlayLab.LiveScene" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Owned background bitmap context allocation failed."}];return NO;}
    CGContextSetRGBFillColor(ctx,.055,.075,.10,1); CGContextFillRect(ctx,CGRectMake(0,0,kInputWidth,kInputHeight)); CGContextTranslateCTM(ctx,0,kInputHeight); CGContextScaleCTM(ctx,sx,-sy); CGContextTranslateCTM(ctx,-offset.x,-offset.y); [self.liveSceneContent.layer renderInContext:ctx]; CGContextRelease(ctx);
    [slot.texture replaceRegion:MTLRegionMake2D(0,0,kInputWidth,kInputHeight) mipmapLevel:0 withBytes:slot.pixels.bytes bytesPerRow:kInputWidth*4];
    slot.generation=++self.liveGeneration; slot.contentOffset=offset; slot.viewportRect=CGRectMake(offset.x,offset.y,vw,vh); slot.scaleTo480x360=CGSizeMake(sx,sy); slot.sha256=[self sha256ForData:slot.pixels]; self.liveCurrentSlot=slot; self.liveCaptureInvalidated=NO; self.liveLastCaptureTime=CACurrentMediaTime();
    if(error)*error=nil; return YES;
}
- (LiveInputSlot *)captureLiveSceneAtTime:(CFTimeInterval)now force:(BOOL)force error:(NSError **)error {
    if(!force && now-self.liveLastCaptureTime < (1.0/15.0)){if(error)*error=nil;return self.liveCurrentSlot;}
    [self setupLiveInputSlots]; LiveInputSlot *slot=[self availableLiveInputSlot]; if(!slot){self.liveCaptureInvalidated=YES;if(error)*error=[NSError errorWithDomain:@"NativePlayLab.LiveScene" code:4 userInfo:@{NSLocalizedDescriptionKey:@"All three input slots are still in flight; retained prior/native content."}];return nil;}
    if(![self renderLiveSceneIntoSlot:slot error:error]){self.liveCaptureInvalidated=YES;return nil;} return slot;
}
- (void)setLiveSceneEnabled:(BOOL)enabled {
    self.liveSceneMode=enabled; self.liveSceneHost.hidden=!enabled;
    [self.liveSceneModeButton setTitle:(enabled?@"Scene: App-owned live scene · tap for fixed botanical":@"Scene: fixed-botanical · tap for App-owned live scene") forState:UIControlStateNormal];
    if(!enabled){if(self.metalReady){self.frameA.metalView.hidden=NO;self.frameB.metalView.hidden=NO;[self setStatus:@"FIXED BOTANICAL · original 480×360 input; 12-case self-check remains fixed-source."];[self requestFrame];}return;}
    [self setupLiveInputSlots]; self.liveCaptureInvalidated=YES; NSError *error=nil; LiveInputSlot *slot=[self captureLiveSceneAtTime:CACurrentMediaTime() force:YES error:&error];
    if(slot&&self.metalReady){self.frameA.metalView.hidden=NO;self.frameB.metalView.hidden=NO;[self setStatus:@"APP-OWNED LIVE SCENE · UIKit subtree sampled at 480×360; not a system backdrop."];[self requestFrame];}
    else {if(!self.liveCurrentSlot){self.frameA.metalView.hidden=YES;self.frameB.metalView.hidden=YES;}[self setStatus:[NSString stringWithFormat:@"LIVE INPUT FAIL · native scroll content remains visible · %@",error.localizedDescription?:@"Metal pipeline unavailable"]];}
}
- (void)toggleLiveSceneMode { if(self.testRunning)return; [self setLiveSceneEnabled:!self.liveSceneMode]; }

- (void)loadInput {
    NSURL *url=[[NSBundle mainBundle] URLForResource:@"InputBotanical" withExtension:@"png"];
    NSData *data=url?[NSData dataWithContentsOfURL:url]:nil;
    UIImage *image=data?[UIImage imageWithData:data scale:1.0]:nil;
    if (!image.CGImage || CGImageGetWidth(image.CGImage)!=kInputWidth || CGImageGetHeight(image.CGImage)!=kInputHeight) { self.sourceImage=nil; return; }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *actual=[NSMutableString stringWithCapacity:64]; for (NSUInteger i=0;i<sizeof(digest);i++) [actual appendFormat:@"%02x",digest[i]];
    if (![actual isEqualToString:self.inputSHA256]) { self.sourceImage=nil; self.manifest=nil; return; }
    self.sourceImage=image; self.frameA.sourceView.image=image; self.frameB.sourceView.image=image;
}

- (void)installMetalViews {
    for (NSInteger role=0;role<2;role++) {
        PlayLabFrame *frame=role==0?self.frameA:self.frameB;
        PlayPane *view=[[PlayPane alloc] initWithFrame:CGRectZero device:self.device]; view.translatesAutoresizingMaskIntoConstraints=NO; view.owner=self; view.role=role; view.paused=YES; view.enableSetNeedsDisplay=NO; view.autoResizeDrawable=YES; view.framebufferOnly=YES; view.colorPixelFormat=MTLPixelFormatBGRA8Unorm_sRGB; view.clearColor=MTLClearColorMake(0,0,0,0); view.opaque=NO; view.multipleTouchEnabled=YES; view.backgroundColor=UIColor.clearColor; view.hidden=YES; [frame insertSubview:view belowSubview:frame.heading]; frame.metalView=view;
        [NSLayoutConstraint activateConstraints:@[[view.topAnchor constraintEqualToAnchor:frame.topAnchor],[view.bottomAnchor constraintEqualToAnchor:frame.bottomAnchor],[view.leadingAnchor constraintEqualToAnchor:frame.leadingAnchor],[view.trailingAnchor constraintEqualToAnchor:frame.trailingAnchor]]];
        if (role==1) { frame.playLabel=[UILabel new]; frame.playLabel.translatesAutoresizingMaskIntoConstraints=NO; frame.playLabel.text=@"▶ Play"; frame.playLabel.textColor=UIColor.whiteColor; frame.playLabel.font=[UIFont systemFontOfSize:23 weight:UIFontWeightBold]; frame.playLabel.shadowColor=[UIColor colorWithWhite:0 alpha:.65]; frame.playLabel.shadowOffset=CGSizeMake(0,1); frame.playLabel.textAlignment=NSTextAlignmentCenter; frame.playLabel.userInteractionEnabled=NO; [frame addSubview:frame.playLabel]; [NSLayoutConstraint activateConstraints:@[[frame.playLabel.centerXAnchor constraintEqualToAnchor:frame.centerXAnchor],[frame.playLabel.centerYAnchor constraintEqualToAnchor:frame.centerYAnchor]]]; }
    }
}

- (void)loadInputTexture {
    MTKTextureLoader *loader=[[MTKTextureLoader alloc] initWithDevice:self.device]; NSError *error=nil;
    NSDictionary *options=@{MTKTextureLoaderOptionSRGB:@YES,MTKTextureLoaderOptionTextureUsage:@(MTLTextureUsageShaderRead),MTKTextureLoaderOptionTextureStorageMode:@(MTLStorageModeShared),MTKTextureLoaderOptionOrigin:MTKTextureLoaderOriginTopLeft};
    self.inputTexture=[loader newTextureWithCGImage:self.sourceImage.CGImage options:options error:&error];
    MTLSamplerDescriptor *sd=[MTLSamplerDescriptor new]; sd.minFilter=MTLSamplerMinMagFilterLinear; sd.magFilter=MTLSamplerMinMagFilterLinear; sd.sAddressMode=MTLSamplerAddressModeClampToEdge; sd.tAddressMode=MTLSamplerAddressModeClampToEdge; self.sampler=[self.device newSamplerStateWithDescriptor:sd];
    if (!self.inputTexture || !self.sampler) { NSLog(@"[NativePlayLab] source texture/sampler load failed: %@",error.localizedDescription); self.inputTexture=nil; }
}

- (void)createPipeline {
    NSBundle *bundle=NSBundle.mainBundle;
    NSURL *url=[bundle URLForResource:@"PlayLens" withExtension:@"metal"];
    NSURL *sharedURL=[bundle URLForResource:@"PlayMaterialShared" withExtension:@"h"];
    NSError *error=nil; NSData *sourceData=url?[NSData dataWithContentsOfURL:url]:nil, *sharedData=sharedURL?[NSData dataWithContentsOfURL:sharedURL]:nil;
    NSString *metalSource=sourceData?[[NSString alloc] initWithData:sourceData encoding:NSUTF8StringEncoding]:nil;
    NSString *sharedSource=sharedData?[[NSString alloc] initWithData:sharedData encoding:NSUTF8StringEncoding]:nil;
    if (!metalSource || !sharedSource) { [self fail:[NSString stringWithFormat:@"PlayLens.metal or PlayMaterialShared.h missing/read failed: %@",error.localizedDescription?:@"no bundled source"]]; return; }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; NSMutableString *actual=[NSMutableString stringWithCapacity:64];
    CC_SHA256(sourceData.bytes,(CC_LONG)sourceData.length,digest); for(NSUInteger i=0;i<sizeof(digest);i++) [actual appendFormat:@"%02x",digest[i]];
    unsigned char sharedDigest[CC_SHA256_DIGEST_LENGTH]; NSMutableString *sharedActual=[NSMutableString stringWithCapacity:64];
    CC_SHA256(sharedData.bytes,(CC_LONG)sharedData.length,sharedDigest); for(NSUInteger i=0;i<sizeof(sharedDigest);i++) [sharedActual appendFormat:@"%02x",sharedDigest[i]];
    if (![actual isEqualToString:self.nativeShaderSHA256] || ![sharedActual isEqualToString:self.nativeMaterialSharedSHA256]) { [self fail:@"Bundled MSL/shared material SHA-256 does not match manifest."]; return; }
    NSString *source=[NSString stringWithFormat:@"%@\n%@",sharedSource,metalSource];
    id<MTLLibrary> library=[self.device newLibraryWithSource:source options:nil error:&error];
    if (!library) { [self fail:[NSString stringWithFormat:@"Metal newLibraryWithSource failed: %@",error.localizedDescription?:@"unknown compiler error"]]; return; }
    id<MTLFunction> vertex=[library newFunctionWithName:@"playVertex"], fragment=[library newFunctionWithName:@"playFragment"];
    if (!vertex || !fragment) { [self fail:@"Metal function lookup failed (playVertex/playFragment). Input remains visible."]; return; }
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new]; pd.label=@"Native Play25 isolated A/B"; pd.vertexFunction=vertex; pd.fragmentFunction=fragment; pd.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm_sRGB; pd.rasterSampleCount=1;
    self.pipeline=[self.device newRenderPipelineStateWithDescriptor:pd error:&error];
    if (!self.pipeline) [self fail:[NSString stringWithFormat:@"Metal pipeline creation failed: %@",error.localizedDescription?:@"unknown pipeline error"]];
}

- (void)fail:(NSString *)message {
    [self cancelTouchOwnershipFromSource:@"controller.failureCleanup"]; [self stopFrames]; self.metalReady=NO; self.frameA.metalView.hidden=YES; self.frameB.metalView.hidden=YES;
    self.frameA.playLabel.hidden=YES; self.frameB.playLabel.hidden=NO;
    self.testButton.enabled=NO; self.testButton.alpha=.45; [self setStatus:[@"FAIL · " stringByAppendingString:message]];
}
- (void)setStatus:(NSString *)message { self.statusLabel.text=message; }

- (void)updateDrawableSize:(PlayPane *)view {
    CGFloat scale=view.window.screen.scale ?: UIScreen.mainScreen.scale; CGFloat w=MAX(1,view.bounds.size.width*scale), h=MAX(1,view.bounds.size.height*scale);
    CGFloat factor=MIN(1.0,MIN(kMaxDrawableDimension/w,kMaxDrawableDimension/h)); view.drawableSize=CGSizeMake(MAX(1,floor(w*factor)),MAX(1,floor(h*factor)));
}

- (PlayUniforms)uniformForWidth:(NSUInteger)width height:(NSUInteger)height candidate:(BOOL)candidate press:(float)press x:(float)x y:(float)y ior:(float)ior blur:(float)blur tint:(float)tint glare:(float)glare visibility:(float)visibility stages:(simd_float4)stages debug:(BOOL)debug {
    PlayUniforms u={0}; u.viewportPress=(simd_float4){(float)width,(float)height,press,1.0f}; u.touchBezel=(simd_float4){x,y,kBezel,kThickness}; u.optics=(simd_float4){ior,blur,tint,glare}; u.effects=(simd_float4){visibility,stages.x,stages.y,stages.z}; u.flags=(simd_uint4){(uint32_t)stages.w,(uint32_t)debug,(uint32_t)candidate,0}; return u;
}

- (BOOL)encodeDrawToTexture:(id<MTLTexture>)target inputTexture:(id<MTLTexture>)inputTexture uniformBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset width:(NSUInteger)width height:(NSUInteger)height command:(id<MTLCommandBuffer>)command label:(NSString *)label {
    (void)width; (void)height; MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor]; pass.colorAttachments[0].texture=target; pass.colorAttachments[0].loadAction=MTLLoadActionClear; pass.colorAttachments[0].storeAction=MTLStoreActionStore; pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);
    id<MTLRenderCommandEncoder> enc=[command renderCommandEncoderWithDescriptor:pass]; if (!enc) return NO; enc.label=label; [enc setRenderPipelineState:self.pipeline]; [enc setFragmentTexture:inputTexture atIndex:0]; [enc setFragmentSamplerState:self.sampler atIndex:0]; [enc setFragmentBuffer:buffer offset:offset atIndex:0]; [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [enc endEncoding]; return YES;
}

- (void)drawFrameNow {
    if (!self.metalReady || !self.appActive || self.testRunning || self.frameA.metalView.hidden || self.frameB.metalView.hidden) return;
    if (dispatch_semaphore_wait(self.inflight,DISPATCH_TIME_NOW)!=0) return;
    [self updateDrawableSize:self.frameA.metalView]; [self updateDrawableSize:self.frameB.metalView];
    MTLRenderPassDescriptor *pa=self.frameA.metalView.currentRenderPassDescriptor, *pb=self.frameB.metalView.currentRenderPassDescriptor;
    id<CAMetalDrawable> da=self.frameA.metalView.currentDrawable, db=self.frameB.metalView.currentDrawable;
    if (!pa || !pb || !da || !db) { dispatch_semaphore_signal(self.inflight); return; }
    LiveInputSlot *usedSlot=self.liveSceneMode?self.liveCurrentSlot:nil; id<MTLTexture> frameInput=usedSlot?usedSlot.texture:self.inputTexture;
    if(!frameInput){dispatch_semaphore_signal(self.inflight);return;}
    id<MTLBuffer> ring=self.uniformRing[self.frameIndex++%self.uniformRing.count]; PlayUniforms a=[self uniformForWidth:da.texture.width height:da.texture.height candidate:NO press:0 x:self.touchX y:self.touchY ior:kIOR blur:kBlur tint:kTint glare:kGlare visibility:1 stages:(simd_float4){1,1,1,1} debug:NO]; PlayUniforms b=[self uniformForWidth:db.texture.width height:db.texture.height candidate:YES press:self.press x:self.touchX y:self.touchY ior:kIOR blur:kBlur tint:kTint glare:kGlare visibility:1 stages:(simd_float4){1,1,1,1} debug:NO];
    memcpy(ring.contents,&a,sizeof(a)); memcpy((uint8_t *)ring.contents+kUniformStride,&b,sizeof(b));
    id<MTLCommandBuffer> cmd=[self.queue commandBuffer]; if (!cmd) { dispatch_semaphore_signal(self.inflight); [self fail:@"GPU command buffer allocation failed; showing original input."]; return; } cmd.label=@"one-snapshot A/B frame";
    pa.colorAttachments[0].loadAction=MTLLoadActionClear; pa.colorAttachments[0].storeAction=MTLStoreActionStore; pa.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
    id<MTLRenderCommandEncoder> ea=[cmd renderCommandEncoderWithDescriptor:pa]; if (!ea) { dispatch_semaphore_signal(self.inflight); [self fail:@"A render encoder creation failed; showing original input."]; return; } ea.label=@"A · original input"; [ea setRenderPipelineState:self.pipeline]; [ea setFragmentTexture:frameInput atIndex:0]; [ea setFragmentSamplerState:self.sampler atIndex:0]; [ea setFragmentBuffer:ring offset:0 atIndex:0]; [ea drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [ea endEncoding];
    pb.colorAttachments[0].loadAction=MTLLoadActionClear; pb.colorAttachments[0].storeAction=MTLStoreActionStore; pb.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
    id<MTLRenderCommandEncoder> eb=[cmd renderCommandEncoderWithDescriptor:pb]; if (!eb) { dispatch_semaphore_signal(self.inflight); [self fail:@"B render encoder creation failed; showing original input."]; return; } eb.label=@"B · capsule Play25 candidate"; [eb setRenderPipelineState:self.pipeline]; [eb setFragmentTexture:frameInput atIndex:0]; [eb setFragmentSamplerState:self.sampler atIndex:0]; [eb setFragmentBuffer:ring offset:kUniformStride atIndex:0]; [eb drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [eb endEncoding];
    float submittedPress=self.press, submittedTarget=self.target; BOOL ownedAtSubmission=(self.pointerActive && self.activeTouch!=nil);
    [cmd presentDrawable:da]; [cmd presentDrawable:db]; if(usedSlot)usedSlot.inFlightUses++; __weak typeof(self) weakSelf=self;
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> done){
        NativePlayLabViewController *strong=weakSelf; if(!strong)return; dispatch_semaphore_signal(strong.inflight);
        if(done.status==MTLCommandBufferStatusCompleted) {
            dispatch_async(dispatch_get_main_queue(),^{
                if(usedSlot&&usedSlot.inFlightUses)usedSlot.inFlightUses--; strong.framesCompleted++; strong.maxPressInCompletedCommandBuffer=MAX(strong.maxPressInCompletedCommandBuffer,submittedPress);
                if(submittedPress>.05f && !strong.pressCompletionLogged) { strong.pressCompletionLogged=YES; [strong recordAppEvent:@"livePressFrameCompleted" source:@"Metal.liveDrawableCommandBuffer.completed" details:@{@"completedUniformPress":@(submittedPress),@"submittedTarget":@(submittedTarget)}]; }
                if(submittedPress==0.0f && submittedTarget==0.0f && !ownedAtSubmission && strong.awaitingReleaseRecovery && !strong.releaseCompletionLogged) { strong.releaseCompletionLogged=YES; strong.awaitingReleaseRecovery=NO; [strong recordAppEvent:@"liveReleaseZeroFrameCompleted" source:@"Metal.liveDrawableCommandBuffer.completed" details:@{@"completedUniformPress":@(submittedPress),@"submittedTarget":@(submittedTarget)}]; [strong writeInputTraceWithReason:@"normal touch end and completed live B frame at press=0 target=0"]; }
                [strong refreshInputTraceStatus];
            });
        } else { NSString *message=[NSString stringWithFormat:@"GPU frame failed (%@); native scene remains visible.",done.error.localizedDescription?:@"command execution error"]; dispatch_async(dispatch_get_main_queue(),^{if(usedSlot&&usedSlot.inFlightUses)usedSlot.inFlightUses--;[strong fail:message];}); }
    }];
    [cmd commit]; self.framesActuallySubmitted++; self.maxPressActuallySubmitted=MAX(self.maxPressActuallySubmitted,submittedPress);
    if(submittedPress>.05f && !self.pressSubmissionLogged) { self.pressSubmissionLogged=YES; [self recordAppEvent:@"livePressFrameSubmitted" source:@"Metal.liveDrawableCommandBuffer.commit" details:@{@"submittedUniformPress":@(submittedPress),@"submittedTarget":@(submittedTarget),@"frameOrdinal":@(self.framesActuallySubmitted)}]; }
    if(submittedPress==0.0f && submittedTarget==0.0f && !ownedAtSubmission && self.awaitingReleaseRecovery && !self.releaseSubmissionLogged) { self.releaseSubmissionLogged=YES; [self recordAppEvent:@"liveReleaseZeroFrameSubmitted" source:@"Metal.liveDrawableCommandBuffer.commit" details:@{@"submittedUniformPress":@(submittedPress),@"submittedTarget":@(submittedTarget),@"frameOrdinal":@(self.framesActuallySubmitted)}]; }
    [self refreshInputTraceStatus];
}

- (void)requestFrame {
    if (!self.metalReady || !self.appActive) return;
    if (!self.displayLink) { self.previousTime=0; self.displayLink=[CADisplayLink displayLinkWithTarget:self selector:@selector(frameTick:)]; self.displayLink.preferredFramesPerSecond=60; [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes]; }
}
- (void)stopFrames { [self.displayLink invalidate]; self.displayLink=nil; self.previousTime=0; }
- (void)frameTick:(CADisplayLink *)link {
    CFTimeInterval dt=self.previousTime?MIN(link.timestamp-self.previousTime,.05):1.0/60.0; self.previousTime=link.timestamp;
    if(self.liveSceneMode && self.liveCaptureInvalidated && link.timestamp-self.liveLastCaptureTime>=(1.0/15.0)) { NSError *captureError=nil; LiveInputSlot *slot=[self captureLiveSceneAtTime:link.timestamp force:NO error:&captureError]; if(slot){self.frameA.metalView.hidden=NO;self.frameB.metalView.hidden=NO;} else if(!self.liveCurrentSlot){self.frameA.metalView.hidden=YES;self.frameB.metalView.hidden=YES;[self setStatus:[NSString stringWithFormat:@"LIVE INPUT FAIL · visible native UIScrollView retained · %@",captureError.localizedDescription?:@"capture unavailable"]];} else {[self setStatus:[NSString stringWithFormat:@"LIVE UPDATE DEFERRED · visible native UIScrollView retained · %@",captureError.localizedDescription?:@"capture unavailable"]];} }
    float omega=18.0f, delta=self.press-self.target, rate=self.velocity+omega*delta, decay=expf(-omega*(float)dt);
    self.press=fminf(1,fmaxf(0,self.target+(delta+rate*(float)dt)*decay)); self.velocity=(self.velocity-omega*rate*(float)dt)*decay;
    if (fabsf(self.press-self.target)<.001f && fabsf(self.velocity)<.01f) { self.press=self.target; self.velocity=0; }
    [self drawFrameNow];
    if (!self.pointerActive && self.target==0 && self.press==0 && self.velocity==0 && !(self.liveSceneMode && self.liveCaptureInvalidated)) [self stopFrames];
}

- (BOOL)point:(CGPoint)p liesInsideIdleCapsuleInView:(PlayPane *)view {
    if (CGRectIsEmpty(view.bounds) || p.x<0 || p.y<0 || p.x>=view.bounds.size.width || p.y>=view.bounds.size.height) return NO;
    float x=(float)(p.x/view.bounds.size.width*kInputWidth), y=(float)(p.y/view.bounds.size.height*kInputHeight);
    float qx=fabsf(x-240)-154+57, qy=fabsf(y-180)-57+57;
    float d=hypotf(fmaxf(qx,0),fmaxf(qy,0))+fminf(fmaxf(qx,qy),0)-57;
    return d<=0;
}
- (BOOL)beginTouchInPane:(PlayPane *)pane touch:(UITouch *)touch atPoint:(CGPoint)p {
    if (!touch || !pane.userInteractionEnabled || pane!=self.frameB.metalView || !self.metalReady || !self.appActive || self.testRunning || self.activeTouch || self.pointerActive || ![self point:p liesInsideIdleCapsuleInView:pane]) return NO;
    self.activeTouch=touch; self.pointerActive=YES; self.touchX=(float)(p.x/pane.bounds.size.width*kInputWidth); self.touchY=(float)(p.y/pane.bounds.size.height*kInputHeight); self.target=1; self.awaitingReleaseRecovery=NO; self.pressSubmissionLogged=NO; self.pressCompletionLogged=NO; self.releaseSubmissionLogged=NO; self.releaseCompletionLogged=NO; [self requestFrame]; return YES;
}
- (void)moveTouchInPane:(PlayPane *)pane touch:(UITouch *)touch toPoint:(CGPoint)p {
    if (!touch || touch!=self.activeTouch || touch!=pane.trackedTouch || pane!=self.frameB.metalView || !self.pointerActive || !self.appActive || self.testRunning) return;
    self.touchX=(float)(p.x/pane.bounds.size.width*kInputWidth); self.touchY=(float)(p.y/pane.bounds.size.height*kInputHeight);
    self.target=[self point:p liesInsideIdleCapsuleInView:pane]?1:0; [self requestFrame];
}
- (void)endTouchInPane:(PlayPane *)pane touch:(UITouch *)touch cancelled:(BOOL)cancelled {
    if (!touch || touch!=self.activeTouch || touch!=pane.trackedTouch || pane!=self.frameB.metalView) return;
    if (cancelled) { [self cancelTouchOwnershipFromSource:@"controller.cancelledTouchCleanup"]; return; }
    [pane clearTrackedTouch]; self.activeTouch=nil; self.pointerActive=NO; self.target=0; self.awaitingReleaseRecovery=YES; self.releaseSubmissionLogged=NO; self.releaseCompletionLogged=NO; [self requestFrame];
}
- (void)cancelTouchOwnershipFromSource:(NSString *)source {
    NSUInteger sequence=[self traceSequenceForTouch:self.activeTouch create:NO]; BOOL previouslyOwned=(self.pointerActive && self.activeTouch!=nil); float previousPress=self.press, previousTarget=self.target;
    [self.frameA.metalView clearTrackedTouch]; [self.frameB.metalView clearTrackedTouch]; self.activeTouch=nil; self.pointerActive=NO; self.target=0; self.press=0; self.velocity=0; self.awaitingReleaseRecovery=NO;
    [self recordAppEvent:@"controllerOwnershipReset" source:source?:@"controller.cancelTouchOwnership" details:@{@"ownedBeforeReset":@(previouslyOwned),@"touchSequenceBeforeReset":@(sequence),@"pressBeforeReset":@(previousPress),@"targetBeforeReset":@(previousTarget),@"resetPress":@0,@"resetTarget":@0}];
    if (self.metalReady && self.appActive && !self.testRunning) [self requestFrame];
}
- (void)cancelPress { [self cancelTouchOwnershipFromSource:@"controller.cancelPress"]; }
- (void)appWillResign:(NSNotification *)note {
    (void)note; [self recordAppEvent:@"applicationWillResignActive" source:@"UIApplication.willResignActiveNotification" details:@{@"notificationObserved":@YES}];
    self.appActive=NO; [self cancelTouchOwnershipFromSource:@"controller.willResignActiveCleanup"]; [self stopFrames];
    [self writeInputTraceWithReason:@"observed UIApplication.willResignActiveNotification"];
}
- (void)appDidEnterBackground:(NSNotification *)note {
    (void)note; [self recordAppEvent:@"applicationDidEnterBackground" source:@"UIApplication.didEnterBackgroundNotification" details:@{@"notificationObserved":@YES}];
    [self writeInputTraceWithReason:@"observed UIApplication.didEnterBackgroundNotification"];
}
- (void)appDidBecomeActive:(NSNotification *)note {
    (void)note; self.appActive=YES; [self recordAppEvent:@"applicationDidBecomeActive" source:@"UIApplication.didBecomeActiveNotification" details:@{@"notificationObserved":@YES}];
    if (self.metalReady) [self requestFrame]; [self writeInputTraceWithReason:@"observed UIApplication.didBecomeActiveNotification"];
}
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if(scrollView==self.liveSceneScroll && self.liveSceneMode){self.liveCaptureInvalidated=YES;[self requestFrame];}
}
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    if(scrollView==self.liveSceneScroll){self.liveUserScrollCount++;self.liveUserScrollObserved=YES;return;}
    UIGestureRecognizerState panState=self.inputScrollView.panGestureRecognizer.state;
    [self recordAppEvent:@"scrollPanRecognized" source:@"UIKit.UIScrollViewDelegate.scrollViewWillBeginDragging" details:@{@"panState":@(panState),@"recognizedByUIKitDelegate":@YES}];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated]; [self recordAppEvent:@"viewWillDisappear" source:@"UIKit.viewWillDisappear" details:@{@"note":@"view disappearance is not app background evidence"}];
    [self cancelTouchOwnershipFromSource:@"controller.viewWillDisappearCleanup"]; [self stopFrames]; [self writeInputTraceWithReason:@"UIKit.viewWillDisappear; not classified as app background"];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated]; self.appActive=UIApplication.sharedApplication.applicationState==UIApplicationStateActive;
    [self recordAppEvent:@"viewDidAppear" source:@"UIKit.viewDidAppear" details:@{@"note":@"view appearance alone is not app foreground notification evidence"}];
    if (self.appActive && self.metalReady) [self requestFrame];
}

- (id<MTLTexture>)newReadbackTargetWidth:(NSUInteger)w height:(NSUInteger)h {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB width:w height:h mipmapped:NO]; d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead; d.storageMode=MTLStorageModeShared; return [self.device newTextureWithDescriptor:d];
}
- (NSData *)rgbaReadback:(id<MTLTexture>)texture {
    NSUInteger w=texture.width,h=texture.height,bpr=w*4; NSMutableData *bgra=[NSMutableData dataWithLength:bpr*h]; [texture getBytes:bgra.mutableBytes bytesPerRow:bpr fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
    NSMutableData *rgba=[NSMutableData dataWithLength:bpr*h]; const uint8_t *src=bgra.bytes; uint8_t *dst=rgba.mutableBytes;
    for (NSUInteger y=0;y<h;y++) for(NSUInteger x=0;x<w;x++){NSUInteger i=y*bpr+x*4;dst[i]=src[i+2];dst[i+1]=src[i+1];dst[i+2]=src[i];dst[i+3]=src[i+3];}
    return rgba;
}
- (NSData *)pngFromRGBA:(NSData *)rgba width:(NSUInteger)w height:(NSUInteger)h {
    CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)rgba); CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image=CGImageCreate(w,h,8,32,w*4,space,kCGImageAlphaLast|kCGBitmapByteOrder32Big,provider,NULL,NO,kCGRenderingIntentDefault);
    UIImage *ui=image?[UIImage imageWithCGImage:image scale:1 orientation:UIImageOrientationUp]:nil; NSData *png=ui?UIImagePNGRepresentation(ui):nil;
    if(image)CGImageRelease(image); if(space)CGColorSpaceRelease(space); if(provider)CGDataProviderRelease(provider); return png;
}
- (BOOL)writePNG:(NSData *)rgba width:(NSUInteger)w height:(NSUInteger)h name:(NSString *)name error:(NSError **)error {
    NSData *png=[self pngFromRGBA:rgba width:w height:h]; if(!png){ if(error)*error=[NSError errorWithDomain:@"NativePlayLab" code:20 userInfo:@{NSLocalizedDescriptionKey:@"PNG encoding failed"}]; return NO; }
    return [png writeToURL:[[self documentsURL] URLByAppendingPathComponent:name] options:NSDataWritingAtomic error:error];
}
- (NSURL *)documentsURL { return [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject; }
- (BOOL)writeGPUFailure:(NSString *)testID reason:(NSString *)reason error:(NSError **)writeError {
    NSString *createdAt=[[NSISO8601DateFormatter new] stringFromDate:[NSDate date]];
    NSDictionary *report=@{@"createdAt":createdAt,@"scope":@"Native GPU self-check failed before valid readback; no mock pixels are substituted.",@"source":@{@"inputSHA256":self.inputSHA256?:@"unavailable",@"webOpticalSHA256":self.sourceSHA256?:@"unavailable",@"nativePlayLensSHA256":self.nativeShaderSHA256?:@"unavailable",@"manifestSourceSHA256":self.manifestSHA256?:@"unavailable"},@"gpuChecks":@{@"status":@"FAIL",@"readbackPerformed":@NO,@"failure":reason},@"artifactExport":@{@"failureJSONWriteStatusInReport":@"not recorded; checked by app UI"}};
    NSError *serializationError=nil; NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&serializationError];
    if (!json) { if(writeError)*writeError=serializationError; return NO; }
    NSURL *url=[[self documentsURL] URLByAppendingPathComponent:[NSString stringWithFormat:@"native-gpu-%@-failure.json",testID]];
    return [json writeToURL:url options:NSDataWritingAtomic error:writeError];
}
- (void)finishGPUFailure:(NSString *)testID reason:(NSString *)reason {
    NSError *writeError=nil; BOOL reportWritten=[self writeGPUFailure:testID reason:reason error:&writeError];
    self.testRunning=NO; self.testButton.enabled=self.metalReady; [self.testButton setTitle:@"Run native GPU readback self-check" forState:UIControlStateNormal];
    [self cancelTouchOwnershipFromSource:@"controller.gpuFailureCleanup"];
    NSString *export=reportWritten?@"failure JSON saved": [NSString stringWithFormat:@"failure JSON write FAILED: %@",writeError.localizedDescription?:@"unknown export error"];
    [self setStatus:[NSString stringWithFormat:@"GPU CHECK FAIL · %@ · %@",reason,export]];
    if(self.appActive && self.metalReady) [self drawFrameNow];
}

- (void)runLiveSceneExport {
    if(!self.metalReady||self.testRunning||!self.appActive)return;
    self.testRunning=YES; [self cancelPress]; [self stopFrames]; self.testButton.enabled=NO; self.liveSceneTestButton.enabled=NO; self.liveSceneModeButton.enabled=NO; self.liveSceneScroll.scrollEnabled=NO; self.liveUserScrollObserved=NO; self.liveUserScrollCount=0; [self setLiveSceneEnabled:YES];
    NSString *testID=NSUUID.UUID.UUIDString; NSArray *offsets=@[@[@0,@0],@[@0,@240],@[@0,@480]]; NSMutableArray *states=[NSMutableArray arrayWithCapacity:3];
    self.liveTestOffsetActive=YES; self.liveSceneScroll.contentOffset=CGPointZero; [self.liveSceneScroll layoutIfNeeded]; self.liveTestOffsetActive=NO;
    BOOL priorTitleHidden=self.frameB.playLabel.hidden; NSError *captureError=nil; LiveInputSlot *slot=[self captureLiveSceneAtTime:CACurrentMediaTime() force:YES error:&captureError];
    if(!slot){[self finishLiveSceneExport:testID states:states titleCheck:@{@"passed":@NO,@"failure":captureError.localizedDescription?:@"no slot"} failure:captureError.localizedDescription?:@"initial UIKit background capture failed"];return;}
    self.frameB.playLabel.hidden=NO; NSString *titleVisibleHash=slot.sha256;
    self.frameB.playLabel.hidden=YES; BOOL hiddenRendered=[self renderLiveSceneIntoSlot:slot error:&captureError]; NSString *titleHiddenHash=slot.sha256;
    self.frameB.playLabel.hidden=priorTitleHidden; BOOL restoredRendered=[self renderLiveSceneIntoSlot:slot error:&captureError]; NSString *titleRestoredHash=slot.sha256;
    NSDictionary *titleCheck=@{@"sourceTreeExcludesPlayLabel":@YES,@"playLabelVisibleInputSHA256":titleVisibleHash?:@"unavailable",@"playLabelHiddenInputSHA256":titleHiddenHash?:@"unavailable",@"restoredInputSHA256":titleRestoredHash?:@"unavailable",@"hashSameVisibleHidden":@(hiddenRendered&&[titleVisibleHash isEqualToString:titleHiddenHash]),@"hashSameAfterRestore":@(restoredRendered&&[titleVisibleHash isEqualToString:titleRestoredHash]),@"titleRestored":@(self.frameB.playLabel.hidden==priorTitleHidden)};
    [self runLiveSceneExportStep:0 attempts:0 testID:testID offsets:offsets states:states titleCheck:titleCheck slot:slot];
}
- (void)runLiveSceneExportStep:(NSUInteger)index attempts:(NSUInteger)attempts testID:(NSString *)testID offsets:(NSArray *)offsets states:(NSMutableArray<NSDictionary *> *)states titleCheck:(NSDictionary *)titleCheck slot:(LiveInputSlot *)slot {
    if(index>=3){[self finishLiveSceneExport:testID states:states titleCheck:titleCheck failure:nil];return;}
    if(index>0){NSArray *xy=offsets[index]; self.liveTestOffsetActive=YES; self.liveSceneScroll.contentOffset=CGPointMake([xy[0] doubleValue],[xy[1] doubleValue]); [self.liveSceneScroll layoutIfNeeded]; self.liveTestOffsetActive=NO; NSError *captureError=nil; slot=[self captureLiveSceneAtTime:CACurrentMediaTime() force:YES error:&captureError]; if(!slot){if(attempts<30){__weak typeof(self) weakSelf=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(NSEC_PER_SEC/15)),dispatch_get_main_queue(),^{[weakSelf runLiveSceneExportStep:index attempts:attempts+1 testID:testID offsets:offsets states:states titleCheck:titleCheck slot:nil];});return;}[self finishLiveSceneExport:testID states:states titleCheck:titleCheck failure:captureError.localizedDescription?:@"three input slots remained busy"];return;}}
    if(!slot){[self finishLiveSceneExport:testID states:states titleCheck:titleCheck failure:@"No live input slot available."];return;}
    NSUInteger w=kInputWidth,h=kInputHeight; id<MTLTexture> aTarget=[self newReadbackTargetWidth:w height:h], bTarget=[self newReadbackTargetWidth:w height:h]; id<MTLBuffer> uniforms=[self.device newBufferWithLength:kUniformStride*2 options:MTLResourceStorageModeShared];
    if(!aTarget||!bTarget||!uniforms){[self finishLiveSceneExport:testID states:states titleCheck:titleCheck failure:@"Live-scene Metal readback allocation failed."];return;}
    simd_float4 stages=(simd_float4){1,1,1,1}; PlayUniforms a=[self uniformForWidth:w height:h candidate:NO press:0 x:240 y:180 ior:kIOR blur:kBlur tint:kTint glare:kGlare visibility:1 stages:stages debug:NO]; PlayUniforms b=[self uniformForWidth:w height:h candidate:YES press:0 x:240 y:180 ior:kIOR blur:kBlur tint:kTint glare:kGlare visibility:1 stages:stages debug:NO]; memcpy(uniforms.contents,&a,sizeof(a)); memcpy((uint8_t *)uniforms.contents+kUniformStride,&b,sizeof(b));
    id<MTLCommandBuffer> command=[self.queue commandBuffer]; if(!command){[self finishLiveSceneExport:testID states:states titleCheck:titleCheck failure:@"Live-scene Metal command buffer unavailable."];return;} command.label=[NSString stringWithFormat:@"App-owned live scene A/B generation %llu",(unsigned long long)slot.generation];
    BOOL ok=[self encodeDrawToTexture:aTarget inputTexture:slot.texture uniformBuffer:uniforms offset:0 width:w height:h command:command label:@"live scene A input-only"]&&[self encodeDrawToTexture:bTarget inputTexture:slot.texture uniformBuffer:uniforms offset:kUniformStride width:w height:h command:command label:@"live scene B capsule candidate"];
    if(!ok){[self finishLiveSceneExport:testID states:states titleCheck:titleCheck failure:@"Live-scene Metal encoder creation failed."];return;}
    uint64_t generation=slot.generation; CGPoint offset=slot.contentOffset; CGRect viewport=slot.viewportRect; CGSize scale=slot.scaleTo480x360; NSString *inputHash=slot.sha256; slot.inFlightUses++;
    __weak typeof(self) weakSelf=self;
    [command addCompletedHandler:^(id<MTLCommandBuffer> done){NativePlayLabViewController *strong=weakSelf;if(!strong)return;if(done.status!=MTLCommandBufferStatusCompleted){dispatch_async(dispatch_get_main_queue(),^{if(slot.inFlightUses)slot.inFlightUses--;[strong finishLiveSceneExport:testID states:states titleCheck:titleCheck failure:done.error.localizedDescription?:@"Metal live-scene A/B command failed"];});return;}
        NSData *inputRGBA=[NSData dataWithBytes:slot.pixels.bytes length:slot.pixels.length], *aRGBA=[strong rgbaReadback:aTarget], *bRGBA=[strong rgbaReadback:bTarget];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            NSMutableString *base=[NSMutableString stringWithFormat:@"native-live-scene-%@-offset-%02lu",testID,(unsigned long)index]; NSString *inputFile=[base stringByAppendingString:@"-input.png"],*aFile=[base stringByAppendingString:@"-A.png"],*bFile=[base stringByAppendingString:@"-B.png"];
            NSError *pngError=nil; BOOL inputWritten=[strong writePNG:inputRGBA width:w height:h name:inputFile error:&pngError]; NSError *aError=nil; BOOL aWritten=[strong writePNG:aRGBA width:w height:h name:aFile error:&aError]; NSError *bError=nil; BOOL bWritten=[strong writePNG:bRGBA width:w height:h name:bFile error:&bError];
            const uint8_t *src=inputRGBA.bytes,*ap=aRGBA.bytes,*bp=bRGBA.bytes; uint32_t sourceAMax=0,outsideMax=0; uint64_t outsidePixels=0;
            for(NSUInteger i=0;i<w*h*4;i++)sourceAMax=MAX(sourceAMax,(uint32_t)abs((int)src[i]-(int)ap[i]));
            for(NSUInteger y=0;y<h;y++)for(NSUInteger x=0;x<w;x++){if(PlaySDF((float)x+.5f,(float)y+.5f)<=1.0f)continue;NSUInteger i=(y*w+x)*4;for(NSUInteger c=0;c<4;c++)outsideMax=MAX(outsideMax,(uint32_t)abs((int)ap[i+c]-(int)bp[i+c]));outsidePixels++;}
            NSDictionary *previous=index?states.lastObject:nil; BOOL adjacentChanged=index?(![previous[@"inputSHA256"] isEqualToString:inputHash]):NO;
            NSString *aHash=[strong sha256ForData:aRGBA],*bHash=[strong sha256ForData:bRGBA]; NSString *stateJSON=[base stringByAppendingString:@".json"];
            NSDictionary *metadata=@{@"schemaVersion":@1,@"scope":@"Only the app-created LiveSceneContentView subtree was rendered locally; A/B are real Metal readbacks, not system capture.",@"mode":@"app-owned-live-scene",@"offsetState":@(index),@"offsetIsControlledTestNotUserScroll":@YES,@"sourceTree":@{@"class":@"LiveSceneContentView",@"localLayerRenderOnly":@YES,@"includesMetalOutput":@NO,@"includesPlayLabel":@NO,@"includesHeadingsOrControls":@NO},@"coordinateProtocol":@{@"textureDimensions":@[@(w),@(h)],@"contentOffsetPoints":@{@"x":@(offset.x),@"y":@(offset.y)},@"viewportRectInContentPoints":@{@"x":@(viewport.origin.x),@"y":@(viewport.origin.y),@"width":@(viewport.size.width),@"height":@(viewport.size.height)},@"scaleTo480x360":@{@"x":@(scale.width),@"y":@(scale.height)},@"origin":@"UIKit content top-left; one explicit local y-axis transform for bitmap context; same viewport/offset for A and B"},@"input":@{@"file":inputFile,@"sha256":inputHash,@"generation":@(generation),@"written":@(inputWritten)},@"A":@{@"file":aFile,@"sha256":aHash,@"inputGeneration":@(generation),@"written":@(aWritten)},@"B":@{@"file":bFile,@"sha256":bHash,@"inputGeneration":@(generation),@"written":@(bWritten),@"visualAcceptance":@"not inferred from pixel counts; inspect B image"},@"checks":@{@"sameInputGenerationAandB":@(generation==slot.generation),@"sourceToA":@{@"maxByteDelta":@(sourceAMax),@"passAt2ByteTolerance":@(sourceAMax<=2)},@"maskOutside":@{@"maxByteDelta":@(outsideMax),@"pixels":@(outsidePixels),@"passAt2ByteTolerance":@(outsideMax<=2&&outsidePixels>10000)},@"adjacentControlledOffsetInputChanged":@(adjacentChanged),@"actualUserScrollObserved":@(strong.liveUserScrollObserved),@"userScrollDelegateCount":@(strong.liveUserScrollCount),@"titleForegroundExclusion":titleCheck},@"writeErrors":@[(pngError.localizedDescription?:@""),(aError.localizedDescription?:@""),(bError.localizedDescription?:@"")],@"pngDigests":@{@"input":inputWritten?[strong sha256ForData:[NSData dataWithContentsOfURL:[[strong documentsURL] URLByAppendingPathComponent:inputFile]]]:@"write-failed",@"A":aHash,@"B":bHash}};
            NSData *json=[NSJSONSerialization dataWithJSONObject:metadata options:NSJSONWritingPrettyPrinted error:nil]; NSError *jsonError=nil; BOOL jsonWritten=json&&[json writeToURL:[[strong documentsURL] URLByAppendingPathComponent:stateJSON] options:NSDataWritingAtomic error:&jsonError]; NSMutableDictionary *state=[@{@"offsetState":@(index),@"offsetY":@(offset.y),@"inputSHA256":inputHash,@"generation":@(generation),@"AFile":aFile,@"BFile":bFile,@"inputFile":inputFile,@"jsonFile":stateJSON,@"sourceAMaxByteDelta":@(sourceAMax),@"maskOutsideMaxByteDelta":@(outsideMax),@"adjacentInputChanged":@(adjacentChanged),@"allFilesWritten":@(inputWritten&&aWritten&&bWritten&&jsonWritten),@"jsonWritten":@(jsonWritten)} mutableCopy]; if(jsonError)state[@"jsonError"]=jsonError.localizedDescription; if(!inputWritten)state[@"inputWriteError"]=pngError.localizedDescription?:@"unknown"; if(!aWritten)state[@"aWriteError"]=aError.localizedDescription?:@"unknown"; if(!bWritten)state[@"bWriteError"]=bError.localizedDescription?:@"unknown";
            dispatch_async(dispatch_get_main_queue(),^{if(slot.inFlightUses)slot.inFlightUses--;[states addObject:state];[strong runLiveSceneExportStep:index+1 attempts:0 testID:testID offsets:offsets states:states titleCheck:titleCheck slot:nil];});
        });
    }]; [command commit];
}
- (void)finishLiveSceneExport:(NSString *)testID states:(NSArray<NSDictionary *> *)states titleCheck:(NSDictionary *)titleCheck failure:(NSString *)failure {
    self.liveSceneScroll.scrollEnabled=YES; self.liveTestOffsetActive=NO; self.frameB.playLabel.hidden=[titleCheck[@"titleWasHidden"] boolValue];
    NSMutableDictionary *report=[@{@"schemaVersion":@1,@"scope":@"Three app-controlled contentOffsets only; not a real user-scroll claim.",@"mode":@"app-owned-live-scene",@"sourceHashes":@{@"nativePlayLensSHA256":self.nativeShaderSHA256?:@"unavailable",@"frozenInputBotanicalSHA256":self.inputSHA256?:@"unavailable"},@"sampleLimit":@{@"inputSlots":@3,@"captureRateCapHz":@15,@"aAndBShareTextureGeneration":@YES},@"foreground":@{@"playLabelRestored":@(!self.frameB.playLabel.hidden),@"exclusion":titleCheck?:@{}},@"controlledOffsets":states,@"actualUserScroll":@{@"observed":@(self.liveUserScrollObserved),@"delegateCount":@(self.liveUserScrollCount),@"status":@"not inferred from programmatic contentOffset changes"},@"pressStateAfterCheck":@{@"press":@(self.press),@"target":@(self.target),@"releaseRestored":@(self.press==0&&self.target==0)}} mutableCopy]; if(failure.length)report[@"failure"]=failure;
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]; NSError *error=nil; NSString *name=[NSString stringWithFormat:@"native-live-scene-%@.json",testID]; BOOL written=json&&[json writeToURL:[[self documentsURL] URLByAppendingPathComponent:name] options:NSDataWritingAtomic error:&error];
    self.testRunning=NO; self.testButton.enabled=self.metalReady; self.liveSceneTestButton.enabled=self.metalReady; self.liveSceneModeButton.enabled=YES; NSString *status=failure.length?[NSString stringWithFormat:@"LIVE SCENE FAIL · %@ · report %@",failure,written?name:(error.localizedDescription?:@"report write failed")]:[NSString stringWithFormat:@"LIVE SCENE EXPORT %@ · 3 controlled offsets · %@",written?@"WRITTEN":@"JSON WRITE FAILED",name]; [self setStatus:status]; if(self.appActive&&self.metalReady){[self drawFrameNow];if(self.press!=0||self.target!=0)[self requestFrame];}
}

- (void)runGPUReadbackCheck {
    if (!self.metalReady || self.testRunning || !self.appActive || !NSThread.isMainThread) return;
    self.testRunning=YES; [self cancelPress]; [self stopFrames]; self.testButton.enabled=NO;
    [self.testButton setTitle:@"Local renderer runtime test…" forState:UIControlStateNormal];
    [self.testButton setTitle:@"Local renderer runtime test…" forState:UIControlStateDisabled];
    [self setStatus:@"LOCAL RENDERER · app-owned static source · no system backdrop"];
    __weak typeof(self) weakSelf=self;
    RunLocalRendererRuntimeProbe(self.device,self.queue,self.inputTexture,self.testButton,
      ^(NSString *summary,NSString *reportName){
        NativePlayLabViewController *s=weakSelf; if(!s)return;
        s.testRunning=NO; s.testButton.enabled=s.metalReady;
        [s.testButton setTitle:@"Run native GPU readback self-check" forState:UIControlStateNormal];
        [s.testButton setTitle:@"Run native GPU readback self-check" forState:UIControlStateDisabled];
        [s setStatus:summary];
        if(s.appActive&&s.metalReady)[s drawFrameNow];
      });
}

@end
