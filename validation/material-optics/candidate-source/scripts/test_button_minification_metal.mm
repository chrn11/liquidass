/* Real Metal fragment-stage tests for the generated local footprint sampler. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static const char kProbeMSL[] = R"PROBE(
struct LGMinificationProbeArgs { float4 uvDx; float4 dyMode; };
struct LGMinificationProbeOut { float4 position [[position]]; };
vertex LGMinificationProbeOut localMinificationProbeVertex(uint vertexID [[vertex_id]]) {
    const float4 p[3]={float4(-1.0f,-1.0f,0.0f,1.0f),
                       float4( 3.0f,-1.0f,0.0f,1.0f),
                       float4(-1.0f, 3.0f,0.0f,1.0f)};
    LGMinificationProbeOut out; out.position=p[vertexID]; return out;
}
fragment float4 localMinificationProbeFragment(
    LGMinificationProbeOut in [[stage_in]],
    texture2d<float, access::sample> source [[texture(0)]],
    constant LGMinificationProbeArgs &args [[buffer(0)]]) {
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    float2 uv=args.uvDx.xy, dx=args.uvDx.zw, dy=args.dyMode.xy;
    LGMinificationFootprint fp=LGBOAnalyzeMinificationFootprint(dx.x,dx.y,dy.x,dy.y);
    if (args.dyMode.z<0.5f && fp.tapCount>1)
        return localButtonMinifiedSample(source,s,uv,fp);
    return source.sample(s,uv,level(0.0f));
}
)PROBE";

struct ProbeArgs { simd_float4 uvDx; simd_float4 dyMode; };
static id<MTLTexture> MakeTexture(id<MTLDevice> device,NSUInteger w,NSUInteger h,
                                  const std::vector<float> &pixels) {
    if (pixels.size()!=w*h*4) return nil;
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
        MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
    d.usage=MTLTextureUsageShaderRead; d.storageMode=MTLStorageModeShared;
    id<MTLTexture> t=[device newTextureWithDescriptor:d];
    std::vector<uint8_t> bytes(pixels.size());
    for(size_t i=0;i<pixels.size();i++)
        bytes[i]=(uint8_t)std::lround(std::clamp(pixels[i],0.0f,1.0f)*255.0f);
    if (t) [t replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0
                  withBytes:bytes.data() bytesPerRow:w*4];
    return t;
}
static bool Probe(id<MTLDevice> device,id<MTLCommandQueue> queue,
                  id<MTLRenderPipelineState> pipeline,id<MTLTexture> source,
                  simd_float2 uv,simd_float2 dx,simd_float2 dy,bool filter,
                  float result[4]) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
        MTLPixelFormatRGBA32Float width:1 height:1 mipmapped:NO];
    d.usage=MTLTextureUsageRenderTarget; d.storageMode=MTLStorageModeShared;
    id<MTLTexture> target=[device newTextureWithDescriptor:d]; if(!target)return false;
    ProbeArgs args={simd_make_float4(uv.x,uv.y,dx.x,dx.y),
                    simd_make_float4(dy.x,dy.y,filter?0.0f:1.0f,0.0f)};
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=target; pass.colorAttachments[0].loadAction=MTLLoadActionClear;
    pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
    id<MTLCommandBuffer> cb=[queue commandBuffer];
    id<MTLRenderCommandEncoder> enc=[cb renderCommandEncoderWithDescriptor:pass];
    if(!enc)return false;
    [enc setRenderPipelineState:pipeline]; [enc setFragmentTexture:source atIndex:0];
    [enc setFragmentBytes:&args length:sizeof(args) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if(cb.status!=MTLCommandBufferStatusCompleted){
        std::fprintf(stderr,"Metal probe failed: %s\n",cb.error.localizedDescription.UTF8String);return false;
    }
    [target getBytes:result bytesPerRow:4*sizeof(float) fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
    return true;
}
static bool Near(float a,float b,float e=1.0e-5f){return std::fabs(a-b)<=e;}

int main(int argc,const char **argv) {
    @autoreleasepool {
        if(argc!=2){std::fprintf(stderr,"usage: minification_gpu candidate.metal\n");return 2;}
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        if(!device){std::puts("NOT_RUN: no Metal device exposed");return 77;}
        NSError *error=nil;
        NSString *path=[NSString stringWithUTF8String:argv[1]];
        NSString *base=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
        if(!base){std::fprintf(stderr,"cannot read MSL: %s\n",error.localizedDescription.UTF8String);return 2;}
        NSString *complete=[base stringByAppendingString:[NSString stringWithUTF8String:kProbeMSL]];
        id<MTLLibrary> library=[device newLibraryWithSource:complete options:nil error:&error];
        if(!library){std::fprintf(stderr,"Metal library compile failed: %s\n",error.localizedDescription.UTF8String);return 3;}
        id<MTLFunction> vertex=[library newFunctionWithName:@"localMinificationProbeVertex"];
        id<MTLFunction> fragment=[library newFunctionWithName:@"localMinificationProbeFragment"];
        MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
        pd.vertexFunction=vertex; pd.fragmentFunction=fragment;
        pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA32Float;
        id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithDescriptor:pd error:&error];
        if(!pipeline){std::fprintf(stderr,"probe pipeline failed: %s\n",error.localizedDescription.UTF8String);return 4;}
        id<MTLCommandQueue> queue=[device newCommandQueue];if(!queue)return 5;

        constexpr NSUInteger n=32;
        std::vector<float> checker(n*n*4);
        for(NSUInteger y=0;y<n;y++)for(NSUInteger x=0;x<n;x++){
            float v=((x+y)&1)?1.0f:0.0f; size_t i=(y*n+x)*4;
            checker[i]=checker[i+1]=checker[i+2]=v;checker[i+3]=1.0f;
        }
        id<MTLTexture> texture=MakeTexture(device,n,n,checker);if(!texture)return 6;
        float direct[4],identity[4],filtered[4];
        if(!Probe(device,queue,pipeline,texture,simd_make_float2(16.5f/n,16.5f/n),
                  simd_make_float2(1,0),simd_make_float2(0,1),false,direct) ||
           !Probe(device,queue,pipeline,texture,simd_make_float2(16.5f/n,16.5f/n),
                  simd_make_float2(1,0),simd_make_float2(0,1),true,identity) ||
           std::memcmp(direct,identity,sizeof direct)!=0){
            std::fprintf(stderr,"FAIL uncompressed footprint did not preserve direct sample\n");return 7;
        }
        if(!Probe(device,queue,pipeline,texture,simd_make_float2(16.5f/n,16.5f/n),
                  simd_make_float2(4,0),simd_make_float2(0,1),true,filtered) ||
           !Near(filtered[0],0.5f,0.02f) || !Near(filtered[1],0.5f,0.02f) ||
           !Near(filtered[2],0.5f,0.02f) || !Near(filtered[3],1.0f,0.001f) ||
           Near(filtered[0],direct[0],0.1f)){
            std::fprintf(stderr,"FAIL bounded compression did not suppress checker alias: %.4f vs %.4f\n",filtered[0],direct[0]);return 8;
        }

        const float grays[]={0.0f,0.5f,1.0f};
        for(float gray: grays){
            std::vector<float> flat(n*n*4);
            for(size_t i=0;i<flat.size();i+=4){flat[i]=flat[i+1]=flat[i+2]=gray;flat[i+3]=1.0f;}
            id<MTLTexture> uniform=MakeTexture(device,n,n,flat);float out[4];
            float encodedGray=std::round(gray*255.0f)/255.0f;
            if(!uniform||!Probe(device,queue,pipeline,uniform,simd_make_float2(.5f,.5f),
                simd_make_float2(8,0),simd_make_float2(0,3),true,out) ||
                !Near(out[0],encodedGray,2e-6f)||!Near(out[1],encodedGray,2e-6f)||
                !Near(out[2],encodedGray,2e-6f)||!Near(out[3],1.0f,2e-6f)){
                std::fprintf(stderr,"FAIL uniform opaque energy gray=%.2f\n",gray);return 9;
            }
        }

        std::vector<float> alphaEdge(n*n*4);
        for(NSUInteger y=0;y<n;y++)for(NSUInteger x=0;x<n;x++){
            size_t i=(y*n+x)*4;
            if(x<16){alphaEdge[i]=0.2f;alphaEdge[i+1]=0.0f;alphaEdge[i+2]=0.0f;alphaEdge[i+3]=0.25f;}
            else {alphaEdge[i]=0.0f;alphaEdge[i+1]=0.3f;alphaEdge[i+2]=0.0f;alphaEdge[i+3]=0.75f;}
        }
        id<MTLTexture> alphaTexture=MakeTexture(device,n,n,alphaEdge);float alphaOut[4];
        if(!alphaTexture||!Probe(device,queue,pipeline,alphaTexture,simd_make_float2(.5f,16.5f/n),
            simd_make_float2(4,0),simd_make_float2(0,1),true,alphaOut)||
            !Near(alphaOut[0],0.1f,0.001f)||!Near(alphaOut[1],0.5f*(77.0f/255.0f),0.001f)||
            !Near(alphaOut[2],0.0f)||!Near(alphaOut[3],0.5f,0.001f)){
            std::fprintf(stderr,"FAIL premultiplied alpha average %.4f %.4f %.4f %.4f\n",alphaOut[0],alphaOut[1],alphaOut[2],alphaOut[3]);return 10;
        }

        std::vector<float> ramp(n*n*4);
        for(NSUInteger y=0;y<n;y++)for(NSUInteger x=0;x<n;x++){
            size_t i=(y*n+x)*4;ramp[i]=(float)(x+1)/n;ramp[i+1]=ramp[i+2]=0;ramp[i+3]=1;
        }
        id<MTLTexture> rampTexture=MakeTexture(device,n,n,ramp);float edge[4],highEdge[4];
        if(!rampTexture||!Probe(device,queue,pipeline,rampTexture,simd_make_float2(-2.0f,.5f),
            simd_make_float2(8,0),simd_make_float2(0,1),true,edge)||
            !Near(edge[0],8.0f/255.0f)||!Near(edge[1],0)||!Near(edge[2],0)||!Near(edge[3],1)||
            !Probe(device,queue,pipeline,rampTexture,simd_make_float2(3.0f,.5f),
            simd_make_float2(8,0),simd_make_float2(0,1),true,highEdge)||
            !Near(highEdge[0],1)||!Near(highEdge[1],0)||!Near(highEdge[2],0)||!Near(highEdge[3],1)){
            std::fprintf(stderr,"FAIL footprint taps escaped physical half-texel source bounds\n");return 11;
        }
        std::puts("PASS Metal bounded 1/2/4-tap footprint, exact no-minification path, opaque black/gray/white, premul-alpha, source-edge clamp");
        return 0;
    }
}
