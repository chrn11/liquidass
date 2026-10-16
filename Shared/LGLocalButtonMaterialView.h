#pragma once
#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>
#import "LGLocalButtonSourceContract.h"
#import "LGButtonOpticalState.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LGLocalButtonRendererResult) {
    LGLocalButtonRendererDisabled=0,
    LGLocalButtonRendererInactive,
    LGLocalButtonRendererSourceUnavailable,
    LGLocalButtonRendererSourceRejected,
    LGLocalButtonRendererPipelineUnavailable,
    LGLocalButtonRendererReadyForNextDraw
};

/* Provider owns source production and must only return a same-process texture
 * plus its value contract. A source may be a target ROI plus <=16pt/edge local
 * overscan only when sourceOverscanEnabled is explicitly true. It must not
 * screen/window-snapshot or read another app. ownerAlive is explicit lifetime,
 * not IPC identity. */
@interface LGLocalButtonTextureFrame : NSObject
@property(nonatomic,strong,readonly) id<MTLTexture> texture;
@property(nonatomic,readonly) LGLocalButtonSourceContract contract;
- (instancetype)initWithTexture:(id<MTLTexture>)texture
                       contract:(LGLocalButtonSourceContract)contract;
// Provider must not mutate pixels while this frame is retained. The release
// hook fires only after the view AND every in-flight GPU use release the frame.
// Hook must be thread-safe and must not retain the frame itself.
- (instancetype)initWithTexture:(id<MTLTexture>)texture
                       contract:(LGLocalButtonSourceContract)contract
                     leaseEnded:(nullable dispatch_block_t)leaseEnded NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@protocol LGLocalButtonSourceProvider <NSObject>
- (nullable LGLocalButtonTextureFrame *)currentBackgroundFrameForTargetView:(UIView *)target
                                                       monotonicTimestamp:(CFTimeInterval)now;
- (BOOL)isOwnerInstanceAlive:(uint64_t)ownerToken generation:(uint64_t)generation;
@optional
// Providers that capture an explicit owned subtree need the actual material
// sibling for feedback exclusion, and the same target generation as the state.
// Generic immutable-texture providers may omit these lifecycle adapters.
- (BOOL)bindMaterialViewForFeedbackExclusion:(UIView *)materialView
                                      device:(id<MTLDevice>)device;
- (BOOL)updateTargetGeometryGeneration:(uint64_t)generation;
@end

/* Per-view API: the caller explicitly chooses one 44pt return control and
 * places this noninteractive sibling behind its untouched foreground. This
 * class never installs itself, changes hit testing/actions/size, or hides the
 * existing CA/native fallback. ready means source+pipeline validated for the
 * next draw; it is NOT proof of screen presentation or a live system backdrop. */
@class LGLocalButtonMaterialView;
typedef void (^LGLocalButtonAvailabilityHandler)(LGLocalButtonMaterialView *view,
                                                   BOOL available);
@interface LGLocalButtonMaterialView : MTKView <MTKViewDelegate>
/* Main-thread callback for this exact renderer instance. YES means either the
 * current submission serial actually completed, or the separately retained
 * last completed immutable frame is still source/owner/geometry-valid and fresh.
 * It never treats a Ready/pending submission as complete, and does not claim
 * screen presentation. The retained frame is released on replacement, invalidation
 * or its unchanged 100ms source deadline. Capture owners weakly from the block. */
@property(nonatomic,copy,nullable) LGLocalButtonAvailabilityHandler availabilityChangedHandler;
- (nullable instancetype)initWithFrame:(CGRect)frame
                            targetView:(UIView *)targetView
                        sourceProvider:(id<LGLocalButtonSourceProvider>)provider
                 allowApproximateSource:(BOOL)allowApproximateSource
                     explicitOptIn:(BOOL)explicitOptIn NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(CGRect)frame device:(nullable id<MTLDevice>)device NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/* Called by the existing host state owner on the main thread. This copies its
 * current snapshot (no duplicate state machine), asks the provider for one
 * frame, and schedules at most that explicit redraw. No display link/timer. */
- (LGLocalButtonRendererResult)submitOpticalState:(LGButtonOpticalState)state
                                          enabled:(BOOL)enabled;
@property(nonatomic,readonly) LGLocalSourceKind activeSourceKind;
@property(nonatomic,readonly) BOOL isApproximateSource;
@property(nonatomic,readonly) BOOL isSystemLiveBackdrop; /* always NO */
// Completed encoding/command execution, NOT proof of screen presentation.
@property(nonatomic,readonly) uint64_t lastCompletedSubmissionSerial;
@property(nonatomic,readonly) BOOL lastCommandBufferSucceeded;
@property(nonatomic,readonly) BOOL hasCurrentCompletedValidSubmission;
// May be the prior actual completion while a newer submission is pending;
// never a Ready result or stale frame, and never proof of screen presentation.
@property(nonatomic,readonly) BOOL hasDisplayableCompletedMaterial;
@property(nonatomic,readonly) BOOL hasCurrentValidSourceFrame;
- (void)invalidateLocalSource;
@end

NS_ASSUME_NONNULL_END
