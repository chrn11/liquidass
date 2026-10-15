/* Real offscreen Metal render test. Run only on a macOS runner with a Metal device. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "LGLocalButtonUniforms.h"
#import "LGLocalButtonShaderSource.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

static const char kLegacySHA[]="f21b394471fd9d3983502441852e3be0664eec7614a7bcd7652939077c06a72b";
#define kLGLocalButtonCandidateMSL kLGLocalButtonLegacyShader
#define kLGLocalButtonCandidateMSLSHA256 kLGLocalButtonLegacyShaderSHA256
#include "legacy_local_button_shader_fixture.h"
#undef kLGLocalButtonCandidateMSLSHA256
#undef kLGLocalButtonCandidateMSL

typedef struct {
    simd_float2 resolution, outputResolution, screenResolution, cardOrigin;
    simd_float2 wallpaperResolution, lensOrigin;
    float radius, bezelWidth, glassThickness, refractionScale, refractiveIndex;
    simd_float2 wallpaperOrigin, samplingTransformX, samplingTransformY;
    simd_float2 samplingTransformOffset;
    float samplingOrientation, backdropZoom, shapeScale;
    simd_float2 shapeOrigin, shapeSize;
    float useGlyphMask, dispersionStrength, fresnelGlareStrength, borderWidthPixels;
    simd_float4 tintColor;
    float buttonCandidate, buttonCandidateMaxOffset;
    simd_float2 buttonCandidateCenter;
    float buttonCandidatePointScale, buttonCandidateCornerRadius;
    float buttonCandidateRendererScale;
} LegacyUniforms208;
static_assert(sizeof(LegacyUniforms208)==208,"legacy CPU layout must remain 208 bytes");
static_assert(sizeof(LGLocalButtonUniforms)==224,"contact CPU layout must be 224 bytes");

static bool MakePipeline(id<MTLDevice> device, const char *source,
                         MTLPixelFormat format,id<MTLRenderPipelineState> *out) {
    NSString *text=[NSString stringWithUTF8String:source];
    NSError *error=nil;
    id<MTLLibrary> lib=[device newLibraryWithSource:text options:nil error:&error];
    if (!lib) {
        std::fprintf(stderr,"Metal library compile failed: %s\n",error.localizedDescription.UTF8String);
        return false;
    }
    id<MTLFunction> vertex=[lib newFunctionWithName:@"liquidGlassVertex"];
    id<MTLFunction> fragment=[lib newFunctionWithName:@"liquidGlassFragment"];
    if (!vertex || !fragment) { std::fprintf(stderr,"missing LiquidAss Metal entrypoints\n"); return false; }
    MTLRenderPipelineDescriptor *desc=[MTLRenderPipelineDescriptor new];
    desc.vertexFunction=vertex; desc.fragmentFunction=fragment;
    desc.colorAttachments[0].pixelFormat=format;
    error=nil;
    *out=[device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!*out) std::fprintf(stderr,"Metal render pipeline failed: %s\n",error.localizedDescription.UTF8String);
    return *out!=nil;
}

static id<MTLTexture> MakeSource(id<MTLDevice> device) {
    constexpr NSUInteger W=44,H=44;
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB width:W height:H mipmapped:NO];
    d.usage=MTLTextureUsageShaderRead; d.storageMode=MTLStorageModeShared;
    id<MTLTexture> t=[device newTextureWithDescriptor:d];
    if (!t) return nil;
    std::vector<uint8_t> pixels(W*H*4);
    for (NSUInteger y=0;y<H;y++) for (NSUInteger x=0;x<W;x++) {
        size_t i=(y*W+x)*4;
        pixels[i+0]=(uint8_t)std::min<NSUInteger>(255,20+x*3);
        pixels[i+1]=(uint8_t)std::min<NSUInteger>(255,25+y*4);
        pixels[i+2]=(uint8_t)std::min<NSUInteger>(255,15+x*4+y);
        pixels[i+3]=255;
    }
    [t replaceRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0 withBytes:pixels.data() bytesPerRow:W*4];
    return t;
}

static std::vector<uint8_t> Render(id<MTLDevice> device,id<MTLCommandQueue> queue,
    id<MTLRenderPipelineState> pipeline,id<MTLSamplerState> sampler,
    id<MTLTexture> source,const void *uniformBytes,NSUInteger uniformLength) {
    constexpr NSUInteger W=44,H=44;
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB width:W height:H mipmapped:NO];
    d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead; d.storageMode=MTLStorageModeShared;
    id<MTLTexture> target=[device newTextureWithDescriptor:d];
    if (!target) return {};
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=MTLLoadActionClear;
    pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
    id<MTLCommandBuffer> cb=[queue commandBuffer];
    id<MTLRenderCommandEncoder> enc=[cb renderCommandEncoderWithDescriptor:pass];
    if (!enc) return {};
    [enc setRenderPipelineState:pipeline];[enc setFragmentTexture:source atIndex:0];
    [enc setFragmentTexture:source atIndex:1];[enc setFragmentSamplerState:sampler atIndex:0];
    [enc setFragmentBytes:uniformBytes length:uniformLength atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];[cb commit];[cb waitUntilCompleted];
    if (cb.status!=MTLCommandBufferStatusCompleted) {
        std::fprintf(stderr,"Metal render failed: %s\n",cb.error.localizedDescription.UTF8String);return {};
    }
    std::vector<uint8_t> out(W*H*4);
    [target getBytes:out.data() bytesPerRow:W*4 fromRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0];
    return out;
}

static bool BuildUniform(float pressure,bool valid,float x,float y,bool optIn,
                         LGLocalButtonUniforms *out) {
    LGButtonOpticalState s={0};s.eligible=true;s.geometryGeneration=1;
    s.pressure=pressure;s.target=pressure;s.touchValid=valid;s.touchX=x;s.touchY=y;
    s.phase=valid?LGOpticalTrackingInside:LGOpticalIdle;
    LGLocalButtonSourceContract c={0};c.textureWidth=44;c.textureHeight=44;
    c.pointScale=1;c.targetGeometryGeneration=1;
    return LGLocalButtonBuildUniforms(&c,&s,44,44,1,optIn,out);
}

static size_t PixelDifferences(const std::vector<uint8_t>&a,const std::vector<uint8_t>&b) {
    if (a.size()!=b.size() || a.empty()) return SIZE_MAX;
    size_t n=0;for(size_t i=0;i<a.size();i++) if(a[i]!=b[i]) ++n;return n;
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        if (!device) { std::fprintf(stderr,"SKIP: macOS runner exposes no Metal device\n");return 77; }
        if (std::strcmp(kLegacySHA,kLGLocalButtonLegacyShaderSHA256)!=0 ||
            std::strcmp(kLGLocalButtonCandidateMSLSHA256,"c4dc2e5bcf9080c31a38770637da705d292cbbf7544e43dd30a0d41677541551")!=0) {
            std::fprintf(stderr,"shader test fixture/runtime hash mismatch\n");return 1;
        }
        id<MTLCommandQueue> queue=[device newCommandQueue];if(!queue)return 2;
        constexpr MTLPixelFormat format=MTLPixelFormatBGRA8Unorm_sRGB;
        id<MTLRenderPipelineState> current=nil,old=nil;
        if (!MakePipeline(device,kLGLocalButtonCandidateMSL,format,&current)) return 3;
        if (!MakePipeline(device,kLGLocalButtonLegacyShader,format,&old)) return 4;
        id<MTLTexture> source=MakeSource(device);if(!source)return 5;
        MTLSamplerDescriptor *sd=[MTLSamplerDescriptor new];sd.minFilter=MTLSamplerMinMagFilterLinear;
        sd.magFilter=MTLSamplerMinMagFilterLinear;sd.sAddressMode=MTLSamplerAddressModeClampToEdge;sd.tAddressMode=MTLSamplerAddressModeClampToEdge;
        id<MTLSamplerState> sampler=[device newSamplerStateWithDescriptor:sd];if(!sampler)return 7;
        LGLocalButtonUniforms noContact={0};
        if(!BuildUniform(.75f,false,.5f,.5f,true,&noContact))return 8;
        LegacyUniforms208 oldUniforms={0};std::memcpy(&oldUniforms,&noContact,sizeof(oldUniforms));
        auto oldPixels=Render(device,queue,old,sampler,source,&oldUniforms,sizeof(oldUniforms));
        auto noTouchPixels=Render(device,queue,current,sampler,source,&noContact,sizeof(noContact));
        if(oldPixels.empty()||noTouchPixels.empty())return 9;
        if(PixelDifferences(oldPixels,noTouchPixels)!=0) {
            std::fprintf(stderr,"FAIL: new ABI no-contact render differs from frozen 208-byte shader\n");return 10;
        }
        LGLocalButtonUniforms zeroContact=noContact;zeroContact.buttonContactEnabled=1;
        zeroContact.buttonContactCenter=simd_make_float2(.25f,.5f);zeroContact.buttonContactPressure=0;
        auto zeroPixels=Render(device,queue,current,sampler,source,&zeroContact,sizeof(zeroContact));
        if(PixelDifferences(noTouchPixels,zeroPixels)!=0) {
            std::fprintf(stderr,"FAIL: zero contact pressure changed source-plane render\n");return 11;
        }
        LGLocalButtonUniforms left={0},right={0};
        if(!BuildUniform(.75f,true,.25f,.5f,true,&left)||!BuildUniform(.75f,true,.75f,.5f,true,&right))return 12;
        auto leftPixels=Render(device,queue,current,sampler,source,&left,sizeof(left));
        auto rightPixels=Render(device,queue,current,sampler,source,&right,sizeof(right));
        size_t spatialDelta=PixelDifferences(leftPixels,rightPixels);
        if(spatialDelta==0 || spatialDelta==SIZE_MAX) {
            std::fprintf(stderr,"FAIL: left/right contacts did not change rendered source mapping\n");return 13;
        }
        LGLocalButtonUniforms moved={0};if(!BuildUniform(.75f,true,.4f,.63f,true,&moved))return 14;
        auto movedPixels=Render(device,queue,current,sampler,source,&moved,sizeof(moved));
        if(PixelDifferences(leftPixels,movedPixels)==0) {
            std::fprintf(stderr,"FAIL: moved contact has identical GPU result\n");return 15;
        }
        std::printf("PASS real Metal local fragment: legacy208/no-contact exact; zero-contact exact; spatial pixel delta=%zu (GPU readback)\n",spatialDelta);
        return 0;
    }
}
