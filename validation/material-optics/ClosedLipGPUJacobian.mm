#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CommonCrypto/CommonDigest.h>
#include <vector>
#include <cmath>
#include <cstdio>

static NSString *SHA(NSData *d){unsigned char h[CC_SHA256_DIGEST_LENGTH];CC_SHA256(d.bytes,(CC_LONG)d.length,h);NSMutableString*s=[NSMutableString string];for(unsigned c:h)[s appendFormat:@"%02x",c];return s;}
static id<MTLRenderPipelineState> Build(id<MTLDevice>d,NSString *source){
 NSString *probe=[NSString stringWithUTF8String:R"LIPMAP(
float2 actualLipSourceMap(float2 p,uint phase){
    float thick=phase>0?52.8f:108.0f;
    float ref=phase>0?1.8f:2.0f;
    LGButtonOpticsResult q=LGButtonOpticsEvaluateWithContact(p.x,p.y,132.0f,132.0f,66.0f,66.0f,66.0f,48.0f,thick,1.6f,ref,132.0f*7.0f/36.0f,3.0f,3.0f,true,phase>0,phase==1?.06f:.94f,.5f,phase>0?1.0f:0.0f);
    return float2(228.0f*LGBOMapTargetUVToSource((p.x+q.offsetX)/132.0f,132.0f,228.0f,48.0f,true),
                  228.0f*LGBOMapTargetUVToSource((p.y+q.offsetY)/132.0f,132.0f,228.0f,48.0f,true));
}
fragment float4 actualLipJacobianProbe(LGVertexOut in [[stage_in]],constant uint&phase [[buffer(0)]]){
    float2 p=in.position.xy;
    float2 x=actualLipSourceMap(p+float2(.5f,0),phase)-actualLipSourceMap(p-float2(.5f,0),phase);
    float2 y=actualLipSourceMap(p+float2(0,.5f),phase)-actualLipSourceMap(p-float2(0,.5f),phase);
    return float4(x,y);
}
)LIPMAP"];
 NSError*error=nil;id<MTLLibrary>lib=[d newLibraryWithSource:[source stringByAppendingString:probe] options:nil error:&error];
 if(!lib){fprintf(stderr,"Actual MSL probe error: %s\n",error.localizedDescription.UTF8String);return nil;}
 MTLRenderPipelineDescriptor*p=[MTLRenderPipelineDescriptor new];p.vertexFunction=[lib newFunctionWithName:@"liquidGlassVertex"];p.fragmentFunction=[lib newFunctionWithName:@"actualLipJacobianProbe"];p.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA32Float;
 return[d newRenderPipelineStateWithDescriptor:p error:&error];
}
int main(int argc,char**argv){@autoreleasepool{
 if(argc!=3)return 2;NSString *path=[NSString stringWithUTF8String:argv[1]],*folder=[NSString stringWithUTF8String:argv[2]];NSData*sourceData=[NSData dataWithContentsOfFile:path];NSString*source=[[NSString alloc]initWithData:sourceData encoding:NSUTF8StringEncoding];id<MTLDevice>d=MTLCreateSystemDefaultDevice();if(!d)return 77;id<MTLCommandQueue>queue=[d newCommandQueue];id<MTLRenderPipelineState>pipeline=Build(d,source);if(!pipeline)return 3;
 NSMutableArray *records=[NSMutableArray array];bool all=true;
 for(uint32_t phase=0;phase<3;phase++){
  MTLTextureDescriptor*desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:132 height:132 mipmapped:NO];desc.usage=MTLTextureUsageRenderTarget;desc.storageMode=MTLStorageModeShared;id<MTLTexture>t=[d newTextureWithDescriptor:desc];
  MTLRenderPassDescriptor*pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=t;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;id<MTLCommandBuffer>cb=[queue commandBuffer];id<MTLRenderCommandEncoder>enc=[cb renderCommandEncoderWithDescriptor:pass];[enc setRenderPipelineState:pipeline];[enc setFragmentBytes:&phase length:sizeof phase atIndex:0];[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[enc endEncoding];[cb commit];[cb waitUntilCompleted];if(cb.status!=MTLCommandBufferStatusCompleted)return 4;
  std::vector<float>raw(132*132*4);[t getBytes:raw.data() bytesPerRow:132*16 fromRegion:MTLRegionMake2D(0,0,132,132) mipmapLevel:0];unsigned count=0,fold=0,lip=0,lipfold=0;double minDet=1e100,maxMajor=0;
  for(int y=0;y<132;y++)for(int x=0;x<132;x++){
   float depth=66-std::hypot(x+.5f-66,y+.5f-66);if(depth<=.75f)continue;
   const float*v=raw.data()+(y*132+x)*4;for(int k=0;k<4;k++)if(!std::isfinite(v[k]))return 5;
   double a=v[0],b=v[1],c=v[2],e=v[3],det=a*e-b*c;double tr=a*a+b*b+c*c+e*e;double disc=std::sqrt(std::fmax(0,tr*tr-4*det*det));double major=std::sqrt(std::fmax(0,.5*(tr+disc)));count++;minDet=std::fmin(minDet,det);maxMajor=std::fmax(maxMajor,major);if(det<0)fold++;if(depth<4.5f){lip++;if(det<0)lipfold++;}
  }
  NSData*bytes=[NSData dataWithBytes:raw.data() length:raw.size()*sizeof(float)];NSString*name=[NSString stringWithFormat:@"lip-source-jacobian-phase%u.rgba32f",phase];if(![bytes writeToFile:[folder stringByAppendingPathComponent:name] atomically:YES])return 6;bool ok=count==13384&&fold==0&&maxMajor<=4;all=all&&ok;
  [records addObject:@{@"phase":@(phase),@"actualCompletedMetalReadback":@YES,@"rawFile":name,@"rawSHA256":SHA(bytes),@"width":@132,@"height":@132,@"format":@"RGBA32Float little-endian columnsJxx,Jxy,Jyx,Jyy",@"interiorCount":@(count),@"negativeDeterminantPixels":@(fold),@"closedLipCount":@(lip),@"closedLipNegativeDeterminants":@(lipfold),@"minimumDeterminant":@(minDet),@"maximumMajorSingularValue":@(maxMajor),@"pass":@(ok)}];
 }
 NSDictionary*r=@{@"scope":@"Actual GPU source-map finite differences at output pixel centers, +/-0.5px; not screen presentation, AA texture sampling or a global no-fold theorem",@"shaderSHA256":SHA(sourceData),@"actualDevice":d.name?:@"unknown",@"allPass":@(all),@"records":records};NSData*j=[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];if(!j||![j writeToFile:[folder stringByAppendingPathComponent:@"closed-lip-actual-gpu-jacobian.json"] atomically:YES])return 7;puts(all?"PASS actual Metal mapping finite-difference Jacobian idle/press":"FAIL actual Metal mapping finite-difference Jacobian");return all?0:8;
}}
