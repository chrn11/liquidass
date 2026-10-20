#pragma once
#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>
#import "LGLocalButtonMaterialView.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LGAppOwnedButtonSourceStatus) {
    LGAppOwnedButtonSourceStatusReady=0,
    LGAppOwnedButtonSourceStatusDisabledByBuildGate,
    LGAppOwnedButtonSourceStatusInvalidConfiguration,
    LGAppOwnedButtonSourceStatusMainThreadRequired,
    LGAppOwnedButtonSourceStatusOwnerUnavailable,
    LGAppOwnedButtonSourceStatusRendererNotBound,
    LGAppOwnedButtonSourceStatusWrongTarget,
    LGAppOwnedButtonSourceStatusSceneOrWindowMismatch,
    LGAppOwnedButtonSourceStatusFeedbackHierarchy,
    LGAppOwnedButtonSourceStatusUnsupportedTransform,
    LGAppOwnedButtonSourceStatusTargetGenerationMissing,
    LGAppOwnedButtonSourceStatusTargetGenerationRequired,
    LGAppOwnedButtonSourceStatusSourceDomainUnavailable,
    LGAppOwnedButtonSourceStatusUnsupportedLayerContent,
    LGAppOwnedButtonSourceStatusBitmapAllocationFailed,
    LGAppOwnedButtonSourceStatusTransparentCaptureRejected,
    LGAppOwnedButtonSourceStatusTextureAllocationFailed,
    LGAppOwnedButtonSourceStatusLeaseContention,
    LGAppOwnedButtonSourceStatusCaptureRateLimited
};

/* Captures only sourceRoot.layer into a <=76pt bounded CPU bitmap. The host
 * explicitly vouches that sourceRoot is an App-owned background subtree.
 * This is not zero-copy, not a system/window capture and not real-time CA. */
@interface LGAppOwnedButtonSourceProvider : NSObject <LGLocalButtonSourceProvider>
- (nullable instancetype)initWithSourceRoot:(UIView *)sourceRoot
                                 targetView:(UIView *)targetView
                                     device:(id<MTLDevice>)device
                                edgePadding:(UIEdgeInsets)edgePadding
                             explicitOptIn:(BOOL)explicitOptIn NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/* Call after both views are installed in the same owned scene. The caller
 * passes the already-created material sibling and its device. Capture stays
 * disabled until this feedback-exclusion binding succeeds. */
- (BOOL)bindMaterialViewForFeedbackExclusion:(UIView *)materialView
                                      device:(id<MTLDevice>)device;

/* Host-owned invalidation only; no display link, timer, global observer, or
 * duplicate pressure state. Target geometry generation must match optical
 * state.geometryGeneration before each submit. Generations are monotonic. */
- (BOOL)updateTargetGeometryGeneration:(uint64_t)generation;
- (BOOL)advanceOwnerGeneration;
- (void)markSourceContentDirty;

@property(nonatomic,readonly) LGAppOwnedButtonSourceStatus lastStatus;
@property(nonatomic,readonly) uint64_t ownerInstanceToken;
@property(nonatomic,readonly) uint64_t ownerGeneration;
@end

NS_ASSUME_NONNULL_END
