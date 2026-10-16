#pragma once
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#ifdef __cplusplus
extern "C" {
#endif
// Own explicit subtree only. Never a screenshot/window source or another App.
void RunAppOwnedBackgroundProviderProbe(id<MTLDevice> device,UIView *originalSelfCheckContainer,
    void (^completion)(NSDictionary *report));
#ifdef __cplusplus
}
#endif
