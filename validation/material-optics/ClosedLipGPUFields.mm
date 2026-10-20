#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cmath>
#include <cstdio>
#include <vector>

static id<MTLRenderPipelineState> Pipeline(id<MTLDevice>d,NSString *s) {
 NSString *probe=@"\nstruct LipProbePoint { float x,y,p,unused; };\nfragment float4 lipGeometryProbe(LGVertexOut in [[stage_in]], constant LipProbePoint &a [[buffer(0)]]) {\nfloat thick=a.p>0.0f?52.8f:108.0f; float ref=a.p>0.0f?1.8f:2.0f;\nLGButtonOpticsResult q=LGButtonOpticsEvaluateWithContact(a.x,a.y,132.0f,132.0f,66.0f,66.0f,66.0f,48.0f,thick,1.6f,ref,132.0f*7.0f/36.0f,3.0f,3.0f,true,a.p>0.0f,0.95f,0.5f,a.p);\nfloat w=LGBOImageEdgeRadianceWeight(q,132.0f,132.0f,48.0f,3.0f,1.6f,true,true);\nreturn float4(q.height,q.normalX,q.normalY,w);}\n";
 NSError*e=nil;id<MTLLibrary>lib=[d newLibraryWithSource:[s stringByAppendingString:probe] options:nil error:&e];
 if(!lib){fprintf(stderr,"Actual geometry shader failed: %s\n",e.localizedDescription.UTF8String);return nil;}
 MTLRenderPipelineDescriptor*p=[MTLRenderPipelineDescriptor new];p.vertexFunction=[lib newFunctionWithName:@"liquidGlassVertex"];p.fragmentFunction=[lib newFunctionWithName:@"lipGeometryProbe"];p.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA32Float;
 return [d newRenderPipelineStateWithDescriptor:p error:&e];
}
static bool Read(id<MTLDevice>d,id<MTLCommandQueue>q,id<MTLRenderPipelineState>p,float depth,float pressure,float*out) {
 MTLTextureDescriptor*desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:1 height:1 mipmapped:NO];desc.usage=MTLTextureUsageRenderTarget;desc.storageMode=MTLStorageModeShared;id<MTLTexture>t=[d newTextureWithDescriptor:desc];
 auto pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=t;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
 id<MTLCommandBuffer>c=[q commandBuffer];id<MTLRenderCommandEncoder>e=[c renderCommandEncoderWithDescriptor:pass];float a[4]={132-depth,66,pressure,0};[e setRenderPipelineState:p];[e setFragmentBytes:a length:sizeof a atIndex:0];[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[e endEncoding];[c commit];[c waitUntilCompleted];if(c.status!=MTLCommandBufferStatusCompleted)return false;
 [t getBytes:out bytesPerRow:16 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];for(int k=0;k<4;k++)if(!std::isfinite(out[k]))return false;return true;
}
int main(int argc,char**argv){@autoreleasepool{
 if(argc!=4)return 2;NSError*err=nil;NSString*old=[NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]] encoding:NSUTF8StringEncoding error:&err];NSString*newer=[NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[2]] encoding:NSUTF8StringEncoding error:&err];id<MTLDevice>d=MTLCreateSystemDefaultDevice();if(!d)return 77;id<MTLCommandQueue>q=[d newCommandQueue];id<MTLRenderPipelineState>a=Pipeline(d,old),b=Pipeline(d,newer);if(!a||!b)return 3;
 const float depths[]={-.01f,0,.001f,.01f,.1f,.4f,1.2f,2.881f,3,4.49f,4.5f,4.51f,5,8,12,22,66};NSMutableArray*records=[NSMutableArray array];bool all=true;
 for(float pressure:{0.0f,1.0f})for(float depth:depths){float parent[4],now[4];if(!Read(d,q,a,depth,pressure,parent)||!Read(d,q,b,depth,pressure,now))return 4;
  bool finite=now[0]>=0&&now[3]>=0&&now[3]<=.28f&&now[1]*now[1]+now[2]*now[2]<=1.00001f;bool outer=depth>0||(now[0]==0&&now[1]==0&&now[2]==0&&now[3]==0);bool inner=true;if(depth>=4.5f)for(int k=0;k<3;k++)inner=inner&&std::fabs(parent[k]-now[k])<1e-4f;bool outsideCue=depth<4.5f||now[3]==0;
  float derivativeError=0;if(depth>=.1f&&depth<=22){float before[4],after[4];if(!Read(d,q,b,depth-.005f,pressure,before)||!Read(d,q,b,depth+.005f,pressure,after))return 5;float nz=std::sqrt(std::fmax(0,1-now[1]*now[1]-now[2]*now[2]));derivativeError=std::fabs((after[0]-before[0])/.01f-now[1]/nz);}
  bool gradient=derivativeError<.02f;bool ok=finite&&outer&&inner&&outsideCue&&gradient;all=all&&ok;
  [records addObject:@{@"depthPixels":@(depth),@"pressure":@(pressure),@"height":@(now[0]),@"normalXY":@[@(now[1]),@(now[2])],@"edgeWeight":@(now[3]),@"sameHeightGradientError":@(derivativeError),@"innerMatchesParentHeightAndNormal":@(inner),@"sourceCueAbsentBeyondLip":@(outsideCue),@"pass":@(ok)}];
 }
 NSDictionary*r=@{@"scope":@"Actual compiled MSL geometry field readback RGBA32Float from completed Mac Metal commands. Not screen pixels, physical environment or phone evidence",@"allPass":@(all),@"records":records,@"device":d.name?:@"unknown"};NSData*data=[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&err];if(!data||![data writeToFile:[NSString stringWithUTF8String:argv[3]] atomically:YES])return 6;puts(all?"PASS actual GPU closed-lip field, inner parent equality, gradient and bounded cue":"FAIL actual GPU closed-lip geometry");return all?0:7;
}}
