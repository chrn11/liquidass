#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CommonCrypto/CommonDigest.h>
#include <vector>
#include <cstdio>
#include <cmath>
static NSString *Hash(NSData *d){unsigned char b[CC_SHA256_DIGEST_LENGTH];CC_SHA256(d.bytes,(CC_LONG)d.length,b);NSMutableString*s=[NSMutableString string];for(auto v:b)[s appendFormat:@"%02x",v];return s;}
int main(int argc,char**argv){@autoreleasepool{
 if(argc!=3)return 2;NSString*path=[NSString stringWithUTF8String:argv[1]],*dir=[NSString stringWithUTF8String:argv[2]];NSString*source=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];if(!source)return 3;
 NSString*probe=[NSString stringWithUTF8String:R"WGHT(
fragment float4 angularWeightProbe(LGVertexOut in [[stage_in]],constant uint &phase [[buffer(0)]]) {
 float pressure=phase?1.0f:0.0f;
 LGButtonOpticsResult q=LGButtonOpticsEvaluateWithContact(in.position.x,in.position.y,132,132,66,66,66,48,phase?52.8f:108.0f,1.6f,phase?1.8f:2.0f,132.0f*7.0f/36.0f,3,3,true,phase!=0,phase==1?.06f:.94f,.5f,pressure);
 float actual=LGBOImageEdgeRadianceWeight(q,132,132,48,3,1.6f,true,true);
 float depth=-q.signedDistance;
 float t=clamp(depth/4.5f,0.0f,1.0f),edge=1.0f-t*t*(3-2*t);
 float h=clamp(q.height/4.5f,0.0f,1.0f),cov=h*h*(3-2*h);
 float c=sqrt(max(0.0f,1.0f-q.normalX*q.normalX-q.normalY*q.normalY));
 float exact=0.0f,old=0.0f;
 if(q.valid&&q.height>0&&q.signedDistance<0){
  exact=clamp(edge*LGBODielectricFresnel(c,1.6f)*cov,0.0f,.28f);
  float f0=((1.6f-1)/(1.6f+1))*((1.6f-1)/(1.6f+1));float z=1-c;
  old=clamp(edge*(f0+(1-f0)*z*z*z*z*z)*cov,0.0f,.28f);
 }
 return float4(actual,exact,old,depth);
}
)WGHT"];
 NSError*error=nil;id<MTLDevice>d=MTLCreateSystemDefaultDevice();if(!d)return 77;id<MTLCommandQueue>queue=[d newCommandQueue];id<MTLLibrary>lib=[d newLibraryWithSource:[source stringByAppendingString:probe] options:nil error:&error];if(!lib){fprintf(stderr,"WeightMap MSL: %s\n",error.localizedDescription.UTF8String);return 4;}
 MTLRenderPipelineDescriptor*pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[lib newFunctionWithName:@"liquidGlassVertex"];pd.fragmentFunction=[lib newFunctionWithName:@"angularWeightProbe"];pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA32Float;id<MTLRenderPipelineState>pipe=[d newRenderPipelineStateWithDescriptor:pd error:&error];if(!pipe)return 5;
 NSMutableArray*records=[NSMutableArray array];for(uint32_t phase=0;phase<3;phase++){
  MTLTextureDescriptor*td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:132 height:132 mipmapped:NO];td.usage=MTLTextureUsageRenderTarget;td.storageMode=MTLStorageModeShared;id<MTLTexture>out=[d newTextureWithDescriptor:td];
  MTLRenderPassDescriptor*pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=out;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
  id<MTLCommandBuffer>cb=[queue commandBuffer];id<MTLRenderCommandEncoder>e=[cb renderCommandEncoderWithDescriptor:pass];[e setRenderPipelineState:pipe];[e setFragmentBytes:&phase length:4 atIndex:0];[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[e endEncoding];[cb commit];[cb waitUntilCompleted];if(cb.status!=MTLCommandBufferStatusCompleted)return 6;
  std::vector<float>v(132*132*4);[out getBytes:v.data() bytesPerRow:132*16 fromRegion:MTLRegionMake2D(0,0,132,132) mipmapLevel:0];for(float f:v)if(!std::isfinite(f))return 7;
  NSString*n=[NSString stringWithFormat:@"angular-weight-phase%u.rgba32f",phase];NSData*raw=[NSData dataWithBytes:v.data() length:v.size()*sizeof(float)];if(![raw writeToFile:[dir stringByAppendingPathComponent:n] atomically:YES])return 8;
  [records addObject:@{@"phase":@(phase),@"file":n,@"SHA256":Hash(raw),@"floatCount":@(v.size()),@"actualCompletedCommandBuffer":@YES}];
 }
 NSDictionary*r=@{@"scope":@"Actual MSL angular-weight fields; columns candidate excess / exact Fresnel with old window / parent Schlick window / depth. Ablations share same exact geometry, not environment illumination proof.",@"records":records,@"device":d.name?:@"unknown"};NSData*j=[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];if(!j||![j writeToFile:[dir stringByAppendingPathComponent:@"angular-gpu-weight-fields.json"] atomically:YES])return 9;
 puts("PASS real GPU three-state angular-weight fields recorded; support and image quality require independent analysis");return 0;
}}
