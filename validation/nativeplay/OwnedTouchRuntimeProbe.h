#pragma once
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Main-thread-only, finite NativePlayLab selfcheck fixture. Completion is
 * called once on the main thread after cleanup (or setup failure/timeout). */
void RunOwnedTouchRuntimeProbe(id<MTLDevice> device,
                               UIView *originalSelfCheckButton,
                               void (^completion)(NSDictionary *result));

#ifdef __cplusplus
}
#endif
