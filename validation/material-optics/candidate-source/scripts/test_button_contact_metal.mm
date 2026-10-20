/* Real offscreen Metal render test. Run only on a macOS runner with a Metal device. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CommonCrypto/CommonDigest.h>
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

#define kLGLocalButtonCandidateMSL kLGPrevious224MSL
#define kLGLocalButtonCandidateMSLSHA256 kLGPrevious224SHA
#include "legacy_contact224_shader_fixture.h"
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
static_assert(sizeof(LGLocalButtonUniforms)==240,"local overscan CPU layout must be 240 bytes");

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
    id<MTLTexture> source,const void *uniformBytes,NSUInteger uniformLength,
    NSUInteger outputWidth=0,NSUInteger outputHeight=0) {
    const NSUInteger W=outputWidth?outputWidth:source.width;
    const NSUInteger H=outputHeight?outputHeight:source.height;
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
    LGLocalButtonSourceContract c={0};c.sourceRectInOwnerPoints=CGRectMake(0,0,44,44);
    c.targetRectInOwnerPoints=CGRectMake(0,0,44,44);c.textureWidth=44;c.textureHeight=44;
    c.pointScale=1;c.targetGeometryGeneration=1;
    return LGLocalButtonBuildUniforms(&c,&s,44,44,1,optIn,out);
}

static size_t PixelDifferences(const std::vector<uint8_t>&a,const std::vector<uint8_t>&b) {
    if (a.size()!=b.size() || a.empty()) return SIZE_MAX;
    size_t n=0;for(size_t i=0;i<a.size();i++) if(a[i]!=b[i]) ++n;return n;
}

/* Export real completed-command-buffer readbacks only. CPU prepares source
 * pixels, never optical/material output pixels. */
static bool SaveReadback(NSString *file,const std::vector<uint8_t>&bgra,NSUInteger w,NSUInteger h) {
    if(bgra.size()!=w*h*4)return false;
    NSMutableData *data=[NSMutableData dataWithLength:bgra.size()];uint8_t *p=(uint8_t *)data.mutableBytes;
    for(NSUInteger i=0;i<w*h;i++){p[i*4]=bgra[i*4+2];p[i*4+1]=bgra[i*4+1];p[i*4+2]=bgra[i*4];p[i*4+3]=bgra[i*4+3];}
    CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGImageRef image=CGImageCreate(w,h,8,32,w*4,cs,kCGBitmapByteOrder32Big|kCGImageAlphaPremultipliedLast,provider,NULL,false,kCGRenderingIntentDefault);
    NSURL *url=[NSURL fileURLWithPath:file];CGImageDestinationRef dest=CGImageDestinationCreateWithURL((__bridge CFURLRef)url,CFSTR("public.png"),1,NULL);
    BOOL ok=image&&dest;if(ok){CGImageDestinationAddImage(dest,image,NULL);ok=CGImageDestinationFinalize(dest);}
    if(dest)CFRelease(dest);if(image)CGImageRelease(image);if(provider)CGDataProviderRelease(provider);if(cs)CGColorSpaceRelease(cs);return ok;
}
static NSString *PixelSHA(const std::vector<uint8_t>&pixels) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(pixels.data(),(CC_LONG)pixels.size(),digest);NSMutableString *s=[NSMutableString string];for(unsigned x:digest)[s appendFormat:@"%02x",x];return s;
}
// Real Metal source perturbation, not a CPU-computed material image.
static bool TestFiniteOverscan(id<MTLDevice> device,id<MTLCommandQueue> queue,
    id<MTLRenderPipelineState> pipeline,id<MTLSamplerState> sampler) {
    constexpr NSUInteger sw=228,n=132,origin=48;
    auto texture=[&](const std::vector<uint8_t>&v,NSUInteger w,NSUInteger h){
        MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB width:w height:h mipmapped:NO];
        d.usage=MTLTextureUsageShaderRead;d.storageMode=MTLStorageModeShared;
        id<MTLTexture> t=[device newTextureWithDescriptor:d];
        if(t)[t replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:v.data() bytesPerRow:w*4];return t;
    };
    std::vector<uint8_t> flat(sw*sw*4),altered=flat,crop(n*n*4);
    for(NSUInteger y=0;y<sw;y++)for(NSUInteger x=0;x<sw;x++){
        size_t i=(y*sw+x)*4;flat[i]=flat[i+1]=flat[i+2]=96;flat[i+3]=255;
        std::memcpy(&altered[i],&flat[i],4);
        if(x<origin||x>=origin+n||y<origin||y>=origin+n){
            // Only change surrounding source pixels; target ROI remains exact.
            altered[i]=(uint8_t)(x<origin?230:10);altered[i+1]=(uint8_t)(y<origin?225:35);altered[i+2]=(uint8_t)(x>=origin+n?240:25);
        }
    }
    for(NSUInteger y=0;y<n;y++)for(NSUInteger x=0;x<n;x++){
        std::memcpy(&crop[(y*n+x)*4],&flat[((y+origin)*sw+x+origin)*4],4);
        if(std::memcmp(&flat[((y+origin)*sw+x+origin)*4],&altered[((y+origin)*sw+x+origin)*4],4))return false;
    }
    id<MTLTexture> a=texture(flat,sw,sw),b=texture(altered,sw,sw),c=texture(crop,n,n);if(!a||!b||!c)return false;
    LGLocalButtonSourceContract contract={0};contract.sourceRectInOwnerPoints=CGRectMake(-6,4,76,76);contract.targetRectInOwnerPoints=CGRectMake(10,20,44,44);
    contract.sourceOverscanEnabled=true;contract.textureWidth=contract.textureHeight=sw;contract.pointScale=3;contract.targetGeometryGeneration=1;
    LGButtonOpticalState state={0};state.eligible=true;state.geometryGeneration=1;
    LGLocalButtonUniforms wide={0};if(!LGLocalButtonBuildUniforms(&contract,&state,n,n,3,true,&wide))return false;
    if(wide.resolution.x!=n||wide.radius!=66||wide.buttonSourceTargetOriginPixels.x!=origin||wide.buttonCandidateMaxOffset>26)return false;
    auto base=Render(device,queue,pipeline,sampler,a,&wide,sizeof wide,n,n);
    auto changed=Render(device,queue,pipeline,sampler,b,&wide,sizeof wide,n,n);
    if(base.empty()||changed.empty())return false;
    size_t influenced=0;NSUInteger outsideMax=0;
    for(NSUInteger y=0;y<n;y++)for(NSUInteger x=0;x<n;x++){
        size_t i=(y*n+x)*4;unsigned md=0;for(unsigned ch=0;ch<4;ch++)md=std::max(md,(unsigned)abs((int)base[i+ch]-changed[i+ch]));
        if(hypot((double)x+.5-n*.5,(double)y+.5-n*.5)>=n*.5)outsideMax=std::max(outsideMax,(NSUInteger)md);
        else if(md>1)influenced++;
    }
    if(influenced<10||outsideMax!=0){std::fprintf(stderr,"FAIL outside-source perturbation did not selectively influence the glass: %zu / outside%lu\n",influenced,(unsigned long)outsideMax);return false;}
    contract.sourceRectInOwnerPoints=contract.targetRectInOwnerPoints;contract.textureWidth=contract.textureHeight=n;contract.sourceOverscanEnabled=false;
    LGLocalButtonUniforms local={0};if(!LGLocalButtonBuildUniforms(&contract,&state,n,n,3,true,&local))return false;
    auto cropA=Render(device,queue,pipeline,sampler,c,&local,sizeof local,n,n);
    auto cropB=Render(device,queue,pipeline,sampler,c,&local,sizeof local,n,n);
    if(PixelDifferences(cropA,cropB)!=0)return false;
    // A named edge pixel must change; matching only a global byte count could
    // conceal an incorrectly stretched source-domain implementation.
    const size_t edge=(66*n+0)*4;unsigned edgeChange=0;
    for(unsigned ch=0;ch<3;ch++)edgeChange=std::max(edgeChange,(unsigned)abs((int)base[edge+ch]-changed[edge+ch]));
    if(edgeChange==0)return false;
    LGLocalButtonUniforms mask=wide;mask.outputResolution=simd_make_float2(sw,sw);
    auto masked=Render(device,queue,pipeline,sampler,b,&mask,sizeof mask,sw,sw);
    if(masked.empty())return false;
    for(NSUInteger y=0;y<sw;y++)for(NSUInteger x=0;x<sw;x++){
        if(x>=48&&x<180&&y>=48&&y<180)continue;
        if(masked[(y*sw+x)*4+3]!=0)return false;
    }
    NSString *output=NSProcessInfo.processInfo.environment[@"CONTACT_RESULTS"];
    if(!SaveReadback([output stringByAppendingPathComponent:@"sentinel-wide-base.png"],base,n,n)||
       !SaveReadback([output stringByAppendingPathComponent:@"sentinel-wide-outside-changed.png"],changed,n,n)||
       !SaveReadback([output stringByAppendingPathComponent:@"sentinel-cropped-negative.png"],cropA,n,n))return false;
    NSDictionary *proof=@{@"scope":@"Actual Metal wide-source versus exterior-only perturbation; sentinel source is a causal test, NOT a reflection/visual asset",@"ROIInnerBytesIdentical":@YES,@"outsideROIOnlySourceMutation":@YES,@"influencedInteriorPixelsOver1":@(influenced),@"shapeExteriorMaxDelta":@(outsideMax),@"namedPixel":[NSString stringWithFormat:@"(0,66) channel delta%u",edgeChange],@"croppedNegativeControlExact":@YES,@"targetSize":@132,@"sourceSize":@228,@"sourceOrigin":@48,@"targetMaskNotEnlarged":@YES};
    [[NSJSONSerialization dataWithJSONObject:proof options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[output stringByAppendingPathComponent:@"overscan-exterior-causality.json"] atomically:YES];
    std::printf("PASS true overscan Metal exterior-only sentinel: influenced%zu interior pixels; shape-exterior delta%lu; named edge%u\n",influenced,(unsigned long)outsideMax,edgeChange);return true;
}

static bool TestNoPadAgainstPrevious224(id<MTLDevice> device,id<MTLCommandQueue> queue,
    id<MTLRenderPipelineState> pipeline,id<MTLSamplerState> sampler) {
    id<MTLRenderPipelineState> previous=nil;
    if(!MakePipeline(device,kLGPrevious224MSL,MTLPixelFormatBGRA8Unorm_sRGB,&previous))return false;
    if(std::strcmp(kLGPrevious224SHA,"c4dc2e5bcf9080c31a38770637da705d292cbbf7544e43dd30a0d41677541551"))return false;
    for(unsigned n: {44u,131u,132u,133u})for(unsigned contact=0;contact<2;contact++){
        std::vector<uint8_t> pixels(n*n*4);
        for(unsigned y=0;y<n;y++)for(unsigned x=0;x<n;x++){
            size_t i=(y*n+x)*4;pixels[i]=x*17+y*3;pixels[i+1]=x*2+y*11;pixels[i+2]=x*9+y*5;pixels[i+3]=255;
        }
        MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB width:n height:n mipmapped:NO];desc.usage=MTLTextureUsageShaderRead;desc.storageMode=MTLStorageModeShared;
        id<MTLTexture> source=[device newTextureWithDescriptor:desc];if(!source)return false;
        [source replaceRegion:MTLRegionMake2D(0,0,n,n) mipmapLevel:0 withBytes:pixels.data() bytesPerRow:n*4];
        LGLocalButtonSourceContract c={0};c.sourceRectInOwnerPoints=c.targetRectInOwnerPoints=CGRectMake(0,0,44,44);c.textureWidth=c.textureHeight=n;c.pointScale=n==44?1:3;c.targetGeometryGeneration=11;
        LGButtonOpticalState state={0};state.eligible=true;state.geometryGeneration=11;state.pressure=.75f;state.touchValid=contact;state.phase=contact?LGOpticalTrackingInside:LGOpticalIdle;state.touchX=.25;state.touchY=.5;
        LGLocalButtonUniforms u={0};if(!LGLocalButtonBuildUniforms(&c,&state,n,n,c.pointScale,true,&u)||u.buttonSourceOverscanEnabled!=0)return false;
        auto old=Render(device,queue,previous,sampler,source,&u,224,n,n);
        auto current=Render(device,queue,pipeline,sampler,source,&u,sizeof u,n,n);
        if(PixelDifferences(old,current)!=0){std::fprintf(stderr,"FAIL historical no-pad224 identity n%u contact%u\n",n,contact);return false;}
        c.sourceOverscanEnabled=true;LGLocalButtonUniforms flag={0};if(!LGLocalButtonBuildUniforms(&c,&state,n,n,c.pointScale,true,&flag))return false;
        auto flagZero=Render(device,queue,pipeline,sampler,source,&flag,sizeof flag,n,n);
        if(PixelDifferences(current,flagZero)!=0)return false;
    }
    std::puts("PASS previous224 vs new240 no-pad exact at44/131/132/133px including valid contact and zero-pad opt-in");return true;
}

static bool ExportNaturalOverscan(id<MTLDevice> device,id<MTLCommandQueue> queue,
 id<MTLRenderPipelineState> pipeline,id<MTLSamplerState> sampler) {
 NSString *inputRoot=NSProcessInfo.processInfo.environment[@"CONTACT_INPUT_ROOT"],*out=NSProcessInfo.processInfo.environment[@"CONTACT_RESULTS"];
 NSMutableArray *records=[NSMutableArray array];
 for(NSString *scene in @[@"botanical",@"grid"]) {
  const NSUInteger sw=228,n=132,pad=48;NSData *full=[NSData dataWithContentsOfFile:[inputRoot stringByAppendingPathComponent:[scene stringByAppendingString:@"-228.bgra"]]];if(full.length!=sw*sw*4)return false;
  std::vector<uint8_t> raw((const uint8_t *)full.bytes,(const uint8_t *)full.bytes+full.length),crop(n*n*4);
  for(NSUInteger y=0;y<n;y++)for(NSUInteger x=0;x<n;x++)std::memcpy(&crop[(y*n+x)*4],&raw[((y+pad)*sw+x+pad)*4],4);
  auto texture=[&](const std::vector<uint8_t> &bytes,NSUInteger size){
   MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB width:size height:size mipmapped:NO];d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead;
   id<MTLTexture> t=[device newTextureWithDescriptor:d];if(t)[t replaceRegion:MTLRegionMake2D(0,0,size,size) mipmapLevel:0 withBytes:bytes.data() bytesPerRow:size*4];return t;
  };
  id<MTLTexture> wide=texture(raw,sw),small=texture(crop,n);if(!wide||!small)return false;
  if(!SaveReadback([out stringByAppendingPathComponent:[scene stringByAppendingString:@"-wide-source.png"]],raw,sw,sw)||!SaveReadback([out stringByAppendingPathComponent:[scene stringByAppendingString:@"-target-source.png"]],crop,n,n))return false;
  struct Scenario{const char *name;bool wide,contact;float x,y;};
  const Scenario scenarios[]={{"crop",false,false,.5,.5},{"overscan",true,false,.5,.5},{"overscan-left",true,true,.25,.5},{"overscan-moved",true,true,.6,.63}};
  for(const Scenario &s:scenarios){
   LGLocalButtonSourceContract c={0};c.targetRectInOwnerPoints=CGRectMake(10,20,44,44);c.sourceRectInOwnerPoints=s.wide?CGRectMake(-6,4,76,76):c.targetRectInOwnerPoints;c.pointScale=3;c.textureWidth=c.textureHeight=s.wide?sw:n;c.sourceOverscanEnabled=s.wide;c.targetGeometryGeneration=31;
   LGButtonOpticalState state={0};state.geometryGeneration=31;state.eligible=true;state.pressure=.75f;state.touchValid=s.contact;state.phase=s.contact?LGOpticalTrackingInside:LGOpticalIdle;state.touchX=s.x;state.touchY=s.y;
   LGLocalButtonUniforms u={0};if(!LGLocalButtonBuildUniforms(&c,&state,n,n,3,true,&u))return false;
   auto pixels=Render(device,queue,pipeline,sampler,s.wide?wide:small,&u,sizeof u,n,n);if(pixels.empty())return false;
   unsigned exteriorMax=0,alphaMax=0;
   for(NSUInteger y=0;y<n;y++)for(NSUInteger x=0;x<n;x++){
    size_t i=(y*n+x)*4;alphaMax=std::max(alphaMax,(unsigned)abs((int)pixels[i+3]-crop[i+3]));
    if(hypot((double)x+.5-66,(double)y+.5-66)>=66)for(unsigned ch=0;ch<4;ch++)exteriorMax=std::max(exteriorMax,(unsigned)abs((int)pixels[i+ch]-crop[i+ch]));
   }
   if(exteriorMax>1||alphaMax!=0)return false;
   NSString *name=[NSString stringWithFormat:@"natural-%@-%s.png",scene,s.name];
   if(!SaveReadback([out stringByAppendingPathComponent:name],pixels,n,n))return false;
   [records addObject:@{@"file":name,@"scene":scene,@"state":[NSString stringWithUTF8String:s.name],@"sourceDomainPx":@(s.wide?sw:n),@"targetPx":@(n),@"pointScale":@3,@"targetCapNotEnlarged":@(u.buttonCandidateMaxOffset<26),@"BGRA_SHA256":PixelSHA(pixels),@"shapeExteriorMaxDelta":@(exteriorMax),@"alphaMaxDelta":@(alphaMax),@"contactXY":@[@(u.buttonContactCenter.x),@(u.buttonContactCenter.y)],@"syntheticLocalState":@YES,@"commandCompletedBeforeReadback":@YES}];
  }
 }
 NSDictionary *r=@{@"scope":@"Real macOS Metal own static scene readbacks; same132px target crop and scalar pressure; outer source actual1:1 pixels, not scaled down; no system source/real-world env map claim",@"sourceMSLSHA256":[NSString stringWithUTF8String:kLGLocalButtonCandidateMSLSHA256],@"pointScale":@3,@"targetPoints":@44,@"sourcePaddingPoints":@16,@"pixelRecords":records,@"visualGoalAccepted":@NO};
 return [[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[out stringByAppendingPathComponent:@"actual-overscan-readbacks.json"] atomically:YES];
}

static bool ExportContactImages(id<MTLDevice> device,id<MTLCommandQueue> queue,id<MTLRenderPipelineState> pipeline,id<MTLRenderPipelineState> oldPipeline,id<MTLSamplerState> sampler) {
    NSString *output=NSProcessInfo.processInfo.environment[@"CONTACT_RESULTS"];
    NSString *inputRoot=NSProcessInfo.processInfo.environment[@"CONTACT_INPUT_ROOT"];
    if(!output.length||!inputRoot.length){std::fprintf(stderr,"missing explicit own-input/export paths\n");return false;}
    NSMutableArray *records=[NSMutableArray array];bool allOK=true;
    for(NSString *scene in @[@"botanical",@"grid"]){
        const NSUInteger n=132;NSString *input=[inputRoot stringByAppendingPathComponent:[scene stringByAppendingString:@"-132.bgra"]];NSData *bytes=[NSData dataWithContentsOfFile:input];
        if(bytes.length!=n*n*4)return false;
        MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB width:n height:n mipmapped:NO];td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageShaderRead;
        id<MTLTexture> source=[device newTextureWithDescriptor:td];if(!source)return false;
        [source replaceRegion:MTLRegionMake2D(0,0,n,n) mipmapLevel:0 withBytes:bytes.bytes bytesPerRow:n*4];
        std::vector<uint8_t> raw((const uint8_t *)bytes.bytes,(const uint8_t *)bytes.bytes+bytes.length);
        allOK&=SaveReadback([output stringByAppendingPathComponent:[scene stringByAppendingString:@"-source.png"]],raw,n,n);
        LGLocalButtonSourceContract c={0};c.sourceRectInOwnerPoints=CGRectMake(10,20,44,44);
        c.targetRectInOwnerPoints=CGRectMake(10,20,44,44);
        c.textureWidth=c.textureHeight=(uint32_t)n;c.pointScale=3;c.targetGeometryGeneration=71;
        LGButtonOpticalState state={0};LGOpticalSetEligibility(&state,true,true,true,true,true,71);
        NSMutableArray *states=[NSMutableArray array];
        // All map changes use the actual source pressure reducer and contact
        // tuple; no UIView scale, tint, hand-painted light, or material proxy.
        struct Scenario {const char *name;float x,y;bool valid;};
        const Scenario scenarios[]={{"no-contact",.5f,.5f,false},{"left",.25f,.5f,true},{"right",.75f,.5f,true},{"moved",.4f,.63f,true}};
        std::vector<uint8_t> noContactPixels,leftPixels;
        for(const Scenario &scenario:scenarios){
            state.phase=scenario.valid?LGOpticalTrackingInside:LGOpticalIdle;state.pressure=.75f;state.target=.75f;state.touchValid=scenario.valid;state.touchX=scenario.x;state.touchY=scenario.y;
            LGLocalButtonUniforms u={0};if(!LGLocalButtonBuildUniforms(&c,&state,n,n,3,true,&u))return false;
            auto pixels=Render(device,queue,pipeline,sampler,source,&u,sizeof u);if(pixels.empty())return false;
            NSUInteger outsideMax=0,alphaMax=0;
            for(NSUInteger y=0;y<n;y++)for(NSUInteger x=0;x<n;x++){
                NSUInteger index=(y*n+x)*4;alphaMax=std::max(alphaMax,(NSUInteger)abs((int)pixels[index+3]-(int)raw[index+3]));
                if(hypot((double)x+.5-n*.5,(double)y+.5-n*.5)>=n*.5)for(unsigned ch=0;ch<4;ch++)outsideMax=std::max(outsideMax,(NSUInteger)abs((int)pixels[index+ch]-(int)raw[index+ch]));
            }
            if(outsideMax>1||alphaMax>0)return false;
            NSString *label=[NSString stringWithUTF8String:scenario.name];NSString *name=[NSString stringWithFormat:@"%@-%@.png",scene,label];
            allOK&=SaveReadback([output stringByAppendingPathComponent:name],pixels,n,n);
            if(!scenario.valid){
                noContactPixels=pixels;LegacyUniforms208 original={0};std::memcpy(&original,&u,sizeof original);
                auto prior=Render(device,queue,oldPipeline,sampler,source,&original,sizeof original);
                if(PixelDifferences(pixels,prior)!=0)return false;
            }else{
                if(PixelDifferences(pixels,noContactPixels)==0)return false;
                if(std::strcmp(scenario.name,"left")==0)leftPixels=pixels;
                if(std::strcmp(scenario.name,"right")==0&&PixelDifferences(pixels,leftPixels)==0)return false;
            }
            [records addObject:@{@"file":name,@"scene":scene,@"state":label,@"width":@(n),@"height":@(n),@"contactXY":@[@(scenario.x),@(scenario.y)],@"contactEnabled":@(scenario.valid),@"syntheticInput":@YES,@"BGRA_SHA256":PixelSHA(pixels),@"outsideMaxByteDelta":@(outsideMax),@"alphaMaxByteDelta":@(alphaMax),@"commandCompletedBeforeReadback":@YES}];
        }
        LGButtonOpticalState released={0};LGOpticalSetEligibility(&released,true,true,true,true,true,71);LGOpticalBegin(&released,1,true,true,11,22,44,44);LGOpticalTick(&released,1.2);LGOpticalEnd(&released,1.21,false);LGOpticalTick(&released,3.0);
        LGLocalButtonUniforms final={0};if(!LGLocalButtonBuildUniforms(&c,&released,n,n,3,true,&final))return false;
        auto release=Render(device,queue,pipeline,sampler,source,&final,sizeof final);LGButtonOpticalState idle=released;idle.touchValid=false;
        LGLocalButtonUniforms expected={0};if(!LGLocalButtonBuildUniforms(&c,&idle,n,n,3,true,&expected))return false;
        auto normal=Render(device,queue,pipeline,sampler,source,&expected,sizeof expected);
        if(released.pressure!=0||released.touchValid||PixelDifferences(release,normal)!=0)return false;
        NSString *name=[scene stringByAppendingString:@"-release-idle.png"];allOK&=SaveReadback([output stringByAppendingPathComponent:name],release,n,n);
        [records addObject:@{@"file":name,@"scene":scene,@"state":@"release-idle",@"BGRA_SHA256":PixelSHA(release),@"zeroPressure":@YES,@"exactIdleRGBA":@YES,@"commandCompletedBeforeReadback":@YES}];
    }
    NSDictionary *report=@{@"scope":@"Actual macOS Metal readback; own static botanical/grid source; synthetic local touch snapshots, not UIKit or system-host evidence",@"candidateMSLSHA256":[NSString stringWithUTF8String:kLGLocalButtonCandidateMSLSHA256],@"previousNoContactShaderSHA256":[NSString stringWithUTF8String:kLegacySHA],@"ABI":@240,@"previousABI":@208,@"noContactVsPreviousGPUExact":@YES,@"releaseGPUExactIdle":@YES,@"actualUIKitTouch":@NO,@"systemBackground":@NO,@"pixelRecords":records};
    NSData *reportData=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];allOK&=[reportData writeToFile:[output stringByAppendingPathComponent:@"actual-contact-readbacks.json"] atomically:YES];return allOK;
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        if (!device) { std::fprintf(stderr,"SKIP: macOS runner exposes no Metal device\n");return 77; }
        if (std::strcmp(kLegacySHA,kLGLocalButtonLegacyShaderSHA256)!=0 ||
            std::strcmp(kLGLocalButtonCandidateMSLSHA256,"efe6ff61dcc87625ce4664c940ae55de908878b31255fcab9a7167954e4efb2d")!=0) {
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
        if(!TestFiniteOverscan(device,queue,current,sampler))return 20;
        if(!TestNoPadAgainstPrevious224(device,queue,current,sampler))return 21;
        if(!ExportNaturalOverscan(device,queue,current,sampler))return 22;
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
        if(!ExportContactImages(device,queue,current,old,sampler))return 16;
        std::printf("PASS real Metal local fragment: legacy208/no-contact exact; zero-contact exact; spatial pixel delta=%zu (GPU readback)\n",spatialDelta);
        return 0;
    }
}
