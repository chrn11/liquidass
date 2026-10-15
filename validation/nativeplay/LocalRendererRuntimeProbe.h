#pragma once
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#ifdef __cplusplus
extern "C" {
#endif
void RunLocalRendererRuntimeProbe(id<MTLDevice> device,
                                  id<MTLCommandQueue> queue,
                                  id<MTLTexture> appInputTexture,
                                  UIView *existingSelfCheckButton,
                                  void (^completion)(NSString *status, NSString *reportName));
#ifdef __cplusplus
}
#endif
