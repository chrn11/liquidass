#import <XCTest/XCTest.h>
#import <MetalKit/MetalKit.h>
#import "LGAppOwnedButtonSourceProvider.h"
#import "LGAppOwnedLeasePolicy.h"
#include <math.h>

@interface LGAppOwnedButtonSourceProviderTests : XCTestCase
@property(nonatomic,strong) UIWindow *testWindow;
@property(nonatomic,strong) UIView *container;
@property(nonatomic,strong) UIView *sourceRoot;
@property(nonatomic,strong) UIView *target;
@property(nonatomic,strong) MTKView *material;
@property(nonatomic,strong) id<MTLDevice> device;
@property(nonatomic,strong) LGAppOwnedButtonSourceProvider *provider;
@end

@implementation LGAppOwnedButtonSourceProviderTests

- (void)makeOwnedSiblingFixtureWithBackground:(UIColor *)color {
    self.device=MTLCreateSystemDefaultDevice();
    if (!self.device) { XCTFail(@"Metal device unavailable in test host"); return; }
    self.testWindow=[[UIWindow alloc] initWithFrame:CGRectMake(0,0,320,480)];
    UIViewController *vc=[UIViewController new];
    self.testWindow.rootViewController=vc;
    self.container=vc.view;
    [self.testWindow makeKeyAndVisible];
    self.sourceRoot=[[UIView alloc] initWithFrame:CGRectMake(39,39,78,78)];
    self.sourceRoot.backgroundColor=color;
    self.sourceRoot.opaque=(CGColorGetAlpha(color.CGColor)>=1.0);
    self.target=[[UIView alloc] initWithFrame:CGRectMake(56,56,44,44)];
    self.target.backgroundColor=UIColor.clearColor;
    self.material=[[MTKView alloc] initWithFrame:self.target.frame device:self.device];
    self.material.hidden=YES;
    [self.container addSubview:self.sourceRoot];
    [self.container addSubview:self.target];
    [self.container addSubview:self.material];
    self.provider=[[LGAppOwnedButtonSourceProvider alloc]
        initWithSourceRoot:self.sourceRoot targetView:self.target device:self.device
        edgePadding:UIEdgeInsetsMake(16,16,16,16) explicitOptIn:YES];
    XCTAssertNotNil(self.provider);
    XCTAssertTrue([self.provider updateTargetGeometryGeneration:1]);
    XCTAssertTrue([self.provider bindMaterialViewForFeedbackExclusion:self.material
                                                                 device:self.material.device]);
}

- (LGLocalButtonTextureFrame *)pull {
    return [self.provider currentBackgroundFrameForTargetView:self.target
                                           monotonicTimestamp:CACurrentMediaTime()];
}

- (NSData *)actualCapturedSourceBytes:(id<MTLTexture>)texture {
    NSUInteger row=(NSUInteger)texture.width*4u;
    NSMutableData *bytes=[NSMutableData dataWithLength:row*(NSUInteger)texture.height];
    [texture getBytes:bytes.mutableBytes bytesPerRow:row
           fromRegion:MTLRegionMake2D(0,0,texture.width,texture.height) mipmapLevel:0];
    return bytes;
}

- (void)testPullOnlyCapturesDeclaredOpaqueSubtreeAndDirtyPixelsChange {
#if !LG_LOCAL_BUTTON_RENDERER_COMPILED
    XCTSkip(@"Test target must explicitly build with LG_LOCAL_BUTTON_RENDERER_COMPILED=1");
#endif
    [self makeOwnedSiblingFixtureWithBackground:[UIColor colorWithRed:0.08 green:0.22 blue:0.76 alpha:1]];
    XCTAssertNotNil(self.device);
    if (!self.device) return;
    LGLocalButtonTextureFrame *first=[self pull];
    XCTAssertNotNil(first, @"status=%ld",(long)self.provider.lastStatus);
    if (!first) return;
    XCTAssertEqual(first.contract.sourceKind,LGLocalSourceLiveAppOwnedTexture);
    XCTAssertEqual(first.contract.alphaMode,LGLocalAlphaOpaque);
    XCTAssertTrue(first.contract.backgroundOnly && first.contract.targetForegroundExcluded);
    XCTAssertTrue(first.contract.immutableUntilFrameReleased);
    XCTAssertEqual(first.contract.pixelFormat,81u);
    XCTAssertEqual(first.contract.pointScale,(float)self.testWindow.screen.scale);
    XCTAssertTrue(CGRectEqualToRect(first.contract.targetRectInOwnerPoints,CGRectMake(56,56,44,44)));
    XCTAssertTrue(CGRectEqualToRect(first.contract.sourceRectInOwnerPoints,CGRectMake(40,40,76,76)));
    XCTAssertEqual(first.texture.width,(NSUInteger)llround(76*self.testWindow.screen.scale));
    NSData *before=[self actualCapturedSourceBytes:first.texture];

    /* The source is only the explicit sibling UIView subtree. Change real view
     * content, dirty it, respect the 15Hz cap, and compare source texture bytes;
     * this deliberately does not draw or synthesize material output. */
    self.sourceRoot.backgroundColor=[UIColor colorWithRed:0.88 green:0.12 blue:0.04 alpha:1];
    [self.provider markSourceContentDirty];
    [NSThread sleepForTimeInterval:0.070];
    LGLocalButtonTextureFrame *second=[self pull];
    XCTAssertNotNil(second, @"status=%ld",(long)self.provider.lastStatus);
    if (!second) return;
    XCTAssertEqual(second.contract.sourceKind,LGLocalSourceLiveAppOwnedTexture);
    XCTAssertEqual(second.contract.ownerInstanceToken,first.contract.ownerInstanceToken);
    XCTAssertEqual(second.contract.ownerGeneration,first.contract.ownerGeneration);
    XCTAssertGreaterThan(second.contract.frameGeneration,first.contract.frameGeneration);
    XCTAssertGreaterThanOrEqual(second.contract.frameTimestampMonotonic-
        first.contract.frameTimestampMonotonic,0.065);
    XCTAssertLessThan(second.contract.frameTimestampMonotonic-
        first.contract.frameTimestampMonotonic,0.100);
    XCTAssertLessThan(CACurrentMediaTime()-second.contract.frameTimestampMonotonic,0.100);
    XCTAssertFalse([before isEqualToData:[self actualCapturedSourceBytes:second.texture]]);
}

- (void)testThreeSlotLeaseContentionNeverOverwritesHeldTexture {
#if !LG_LOCAL_BUTTON_RENDERER_COMPILED
    XCTSkip(@"Test target must explicitly build with LG_LOCAL_BUTTON_RENDERER_COMPILED=1");
#endif
    [self makeOwnedSiblingFixtureWithBackground:UIColor.orangeColor];
    XCTAssertNotNil(self.device);
    if (!self.device) return;
    NSMutableArray<LGLocalButtonTextureFrame *> *held=[NSMutableArray array];
    LGLocalButtonTextureFrame *first=[self pull];
    XCTAssertNotNil(first); if (!first) return;
    [held addObject:first];
    /* Repeated cached pulls keep one immutable slot leased, up to four frame
     * leases per slot. No repeated frame generation or timestamp is minted. */
    LGLocalButtonTextureFrame *repeat1=[self pull];
    LGLocalButtonTextureFrame *repeat2=[self pull];
    LGLocalButtonTextureFrame *repeat3=[self pull];
    XCTAssertNotNil(repeat1); XCTAssertNotNil(repeat2); XCTAssertNotNil(repeat3);
    XCTAssertEqual(repeat3.contract.frameGeneration,first.contract.frameGeneration);
    XCTAssertEqual(repeat3.contract.frameTimestampMonotonic,first.contract.frameTimestampMonotonic);
    [held addObjectsFromArray:@[repeat1,repeat2,repeat3]];
    XCTAssertNil([self pull]);
    XCTAssertEqual(self.provider.lastStatus,LGAppOwnedButtonSourceStatusLeaseContention);
    NSData *pinned=[self actualCapturedSourceBytes:first.texture];

    for (NSUInteger slot=1;slot<LG_APP_OWNED_TEXTURE_SLOT_COUNT;slot++) {
        [self.provider markSourceContentDirty];
        [NSThread sleepForTimeInterval:0.070];
        LGLocalButtonTextureFrame *next=[self pull];
        XCTAssertNotNil(next, @"slot=%lu status=%ld",(unsigned long)slot,(long)self.provider.lastStatus);
        if (!next) return;
        XCTAssertNotEqual(next.texture,first.texture);
        [held addObject:next];
    }
    [self.provider markSourceContentDirty];
    [NSThread sleepForTimeInterval:0.070];
    XCTAssertNil([self pull]);
    XCTAssertEqual(self.provider.lastStatus,LGAppOwnedButtonSourceStatusLeaseContention);
    XCTAssertEqualObjects(pinned,[self actualCapturedSourceBytes:first.texture]);
}

- (void)testTransparentPixelsAreRejectedAndWindowOrTargetAncestorIsNotAProvider {
#if !LG_LOCAL_BUTTON_RENDERER_COMPILED
    XCTSkip(@"Test target must explicitly build with LG_LOCAL_BUTTON_RENDERER_COMPILED=1");
#endif
    [self makeOwnedSiblingFixtureWithBackground:UIColor.clearColor];
    XCTAssertNotNil(self.device);
    if (!self.device) return;
    XCTAssertNil([self pull]);
    XCTAssertEqual(self.provider.lastStatus,LGAppOwnedButtonSourceStatusTransparentCaptureRejected);

    LGAppOwnedButtonSourceProvider *windowProvider=[[LGAppOwnedButtonSourceProvider alloc]
        initWithSourceRoot:self.testWindow targetView:self.target device:self.device
        edgePadding:UIEdgeInsetsMake(0,0,0,0) explicitOptIn:YES];
    XCTAssertNil(windowProvider);
    LGAppOwnedButtonSourceProvider *ancestorProvider=[[LGAppOwnedButtonSourceProvider alloc]
        initWithSourceRoot:self.container targetView:self.target device:self.device
        edgePadding:UIEdgeInsetsMake(0,0,0,0) explicitOptIn:YES];
    XCTAssertNil(ancestorProvider);
}

- (void)testTargetMoveRequiresNewExplicitGeometryGeneration {
#if !LG_LOCAL_BUTTON_RENDERER_COMPILED
    XCTSkip(@"Test target must explicitly build with LG_LOCAL_BUTTON_RENDERER_COMPILED=1");
#endif
    [self makeOwnedSiblingFixtureWithBackground:UIColor.blueColor];
    if (!self.device) return;
    LGLocalButtonTextureFrame *first=[self pull];
    XCTAssertNotNil(first); if (!first) return;
    self.target.frame=CGRectOffset(self.target.frame,1,0);
    self.material.frame=self.target.frame;
    XCTAssertNil([self pull]);
    XCTAssertEqual(self.provider.lastStatus,LGAppOwnedButtonSourceStatusTargetGenerationRequired);
    XCTAssertTrue([self.provider updateTargetGeometryGeneration:2]);
    [NSThread sleepForTimeInterval:0.070];
    LGLocalButtonTextureFrame *moved=[self pull];
    XCTAssertNotNil(moved, @"status=%ld",(long)self.provider.lastStatus);
    if (!moved) return;
    XCTAssertEqual(moved.contract.targetGeometryGeneration,2u);
    XCTAssertEqual(CGRectGetMinX(moved.contract.targetRectInOwnerPoints),57.0);
}

- (void)testUnsupportedDrawableSubviewAndMissingPaddingDomainFailClosed {
#if !LG_LOCAL_BUTTON_RENDERER_COMPILED
    XCTSkip(@"Test target must explicitly build with LG_LOCAL_BUTTON_RENDERER_COMPILED=1");
#endif
    [self makeOwnedSiblingFixtureWithBackground:UIColor.greenColor];
    if (!self.device) return;
    MTKView *nestedMetalView=[[MTKView alloc] initWithFrame:CGRectMake(0,0,20,20)
                                                   device:self.device];
    [self.sourceRoot addSubview:nestedMetalView];
    XCTAssertNil([self pull]);
    XCTAssertEqual(self.provider.lastStatus,LGAppOwnedButtonSourceStatusUnsupportedLayerContent);

    [nestedMetalView removeFromSuperview];
    self.sourceRoot.frame=CGRectMake(56,56,44,44);
    [self.provider markSourceContentDirty];
    XCTAssertNil([self pull]);
    XCTAssertEqual(self.provider.lastStatus,LGAppOwnedButtonSourceStatusSourceDomainUnavailable);
}

@end
