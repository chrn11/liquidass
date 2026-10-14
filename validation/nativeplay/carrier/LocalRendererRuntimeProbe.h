#pragma once
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
void RunLocalRendererRuntimeProbe(id<MTLDevice> device,
                                  id<MTLCommandQueue> queue,
                                  id<MTLTexture> appInputTexture,
                                  UIView *existingSelfCheckButton,
                                  void (^completion)(NSString *status, NSString *reportName));
