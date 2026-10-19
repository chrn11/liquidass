/* Real offscreen Metal render test. Run only on a macOS runner with a Metal device. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CommonCrypto/CommonDigest.h>
#import "LGLocalButtonUniforms.h"

#include <algorithm>
#include <cmath>
#include <climits>
#include <cstdio>
#include <cstring>
#include <vector>


static_assert(sizeof(LGLocalButtonUniforms)==240,"review must not silently change production ABI");
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

static double gLastGPUSeconds=0.0;
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
    gLastGPUSeconds=cb.GPUEndTime>cb.GPUStartTime?cb.GPUEndTime-cb.GPUStartTime:0.0;
    std::vector<uint8_t> out(W*H*4);
    [target getBytes:out.data() bytesPerRow:W*4 fromRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0];
    return out;
}

static NSArray *BenchmarkSampling(id<MTLDevice> device,id<MTLCommandQueue> queue,
    id<MTLRenderPipelineState> baseline,id<MTLRenderPipelineState> candidate,
    id<MTLSamplerState> sampler,id<MTLTexture> texture,const LGLocalButtonUniforms &u) {
    std::vector<double>gpu[2],wall[2];
    for(unsigned i=0;i<32;i++)for(unsigned v=0;v<2;v++) {
        CFAbsoluteTime before=CFAbsoluteTimeGetCurrent();
        auto pixels=Render(device,queue,v?candidate:baseline,sampler,texture,&u,sizeof(u),132,132);
        double elapsed=CFAbsoluteTimeGetCurrent()-before;
        if(pixels.size()!=132*132*4)return nil;
        if(i>=8){wall[v].push_back(elapsed);if(gLastGPUSeconds>0&&std::isfinite(gLastGPUSeconds))gpu[v].push_back(gLastGPUSeconds);}
    }
    NSMutableArray *out=[NSMutableArray array];
    for(unsigned v=0;v<2;v++) {
        std::sort(gpu[v].begin(),gpu[v].end());std::sort(wall[v].begin(),wall[v].end());
        id gpuMedian=gpu[v].empty()?(id)[NSNull null]:@(1000.0*gpu[v][gpu[v].size()/2]);
        [out addObject:@{@"variant":v?@"newCandidate":@"frozenBaseline",@"warmup":@8,@"measuredCommandBuffers":@24,
            @"GPUTimeSamplesAvailable":@(gpu[v].size()),@"GPUTimeMedianMilliseconds":gpuMedian,
            @"CPUWallIncludingAllocationAndReadbackMedianMilliseconds":@(1000.0*wall[v][wall[v].size()/2]),
            @"notIPhonePerformanceOrBudgetSignoff":@YES}];
    }
    return out;
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

static NSString *BytesHash(NSData *d) {
 std::vector<uint8_t> b(d.length);if(d.length)memcpy(b.data(),d.bytes,d.length);return PixelSHA(b);
}
static bool EdgeSourceGuards(id<MTLDevice> device,id<MTLCommandQueue> queue,
 id<MTLRenderPipelineState> parent,id<MTLRenderPipelineState> candidate,
 id<MTLSamplerState> sampler,NSString *candidateSource,NSString *inputs,NSString *out,
 NSMutableArray *guards) {
 constexpr NSUInteger T=132,S=228,O=48;const size_t size=T*T*4;
 NSString *zeroSource=[candidateSource stringByReplacingOccurrencesOfString:@"optics.environmentWeight=LGBOImageEdgeRadianceWeight("
  withString:@"optics.environmentWeight=0.0f*LGBOImageEdgeRadianceWeight("];
 if([zeroSource isEqual:candidateSource])return false;
 id<MTLRenderPipelineState> zero=nil;if(!MakePipeline(device,zeroSource.UTF8String,MTLPixelFormatBGRA8Unorm_sRGB,&zero))return false;
 auto textureFor=[&](const std::vector<uint8_t>&src,NSUInteger n)->id<MTLTexture>{
  auto d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB width:n height:n mipmapped:NO];
  d.usage=MTLTextureUsageShaderRead;d.storageMode=MTLStorageModeShared;id<MTLTexture> x=[device newTextureWithDescriptor:d];
  if(x)[x replaceRegion:MTLRegionMake2D(0,0,n,n) mipmapLevel:0 withBytes:src.data() bytesPerRow:n*4];return x;};
 auto contract=[&](NSUInteger n,BOOL pad)->LGLocalButtonSourceContract{
  LGLocalButtonSourceContract c={};c.pointScale=3;c.textureWidth=c.textureHeight=(uint32_t)n;c.pixelFormat=81;c.targetGeometryGeneration=1;
  c.targetRectInOwnerPoints=CGRectMake(0,0,44,44);CGFloat p=(n-T)/6.0;c.sourceRectInOwnerPoints=CGRectMake(-p,-p,n/3.0,n/3.0);c.sourceOverscanEnabled=pad;
  c.ownerInstanceToken=71;c.ownerGeneration=c.frameGeneration=1;c.frameTimestampMonotonic=1;c.sourceKind=LGLocalSourceStaticOwnedAsset;
  c.alphaMode=LGLocalAlphaPremultiplied;c.maskKind=LGLocalMaskRounded44;c.backgroundOnly=c.targetForegroundExcluded=c.immutableUntilFrameReleased=c.sampledRGBIsLinear=c.sampledRGBIsPremultiplied=true;return c;};
 LGButtonOpticalState state={};state.eligible=true;state.geometryGeneration=1;
 auto c=contract(S,YES);LGLocalButtonUniforms u={};if(!LGLocalButtonBuildUniforms(&c,&state,T,T,3,true,&u))return false;
 auto maximum=[&](const std::vector<uint8_t>&a,const std::vector<uint8_t>&b)->unsigned{if(a.size()!=b.size())return UINT_MAX;unsigned m=0;for(size_t i=0;i<a.size();i++)m=std::max(m,(unsigned)abs((int)a[i]-(int)b[i]));return m;};
 NSMutableArray *records=[NSMutableArray array];NSString *png=[out stringByAppendingPathComponent:@"pngs"];
 auto save=[&](NSString *name,const std::vector<uint8_t>&v)->bool{NSString *p=[png stringByAppendingPathComponent:name];if(!SaveReadback(p,v,T,T))return false;NSData *d=[NSData dataWithContentsOfFile:p];[records addObject:@{@"file":name,@"BGRA_SHA256":PixelSHA(v),@"PNG_SHA256":BytesHash(d),@"actualCompletedReadback":@YES}];return true;};
 std::vector<uint8_t> a(S*S*4),b(S*S*4);
 for(NSUInteger y=0;y<S;y++)for(NSUInteger x=0;x<S;x++){
  bool roi=x>=O&&x<O+T&&y>=O&&y<O+T;size_t k=(y*S+x)*4;
  a[k]=roi?128:0;a[k+1]=roi?128:0;a[k+2]=roi?128:255;a[k+3]=255;
  b[k]=roi?128:255;b[k+1]=roi?128:0;b[k+2]=roi?128:0;b[k+3]=255;
 }
 auto ta=textureFor(a,S),tb=textureFor(b,S);if(!ta||!tb)return false;
 auto pa=Render(device,queue,parent,sampler,ta,&u,sizeof u,T,T),pb=Render(device,queue,parent,sampler,tb,&u,sizeof u,T,T);
 auto ea=Render(device,queue,candidate,sampler,ta,&u,sizeof u,T,T),eb=Render(device,queue,candidate,sampler,tb,&u,sizeof u,T,T);
 auto za=Render(device,queue,zero,sampler,ta,&u,sizeof u,T,T);
 if(pa.size()!=size||pb.size()!=size||ea.size()!=size||eb.size()!=size||za.size()!=size)return false;
 unsigned interior=0,edgeOnly=0,outside=0,maxD=0;
 for(NSUInteger y=0;y<T;y++)for(NSUInteger x=0;x<T;x++){
  size_t k=(y*T+x)*4;unsigned d=0,pd=0;for(unsigned j=0;j<3;j++){d=std::max(d,(unsigned)abs((int)ea[k+j]-(int)eb[k+j]));pd=std::max(pd,(unsigned)abs((int)pa[k+j]-(int)pb[k+j]));}
  float dx=x+.5f-66,dy=y+.5f-66;if(dx*dx+dy*dy<66*66){if(d>1)interior++;if(d>1&&pd==0)edgeOnly++;maxD=std::max(maxD,d);}else outside=std::max(outside,d);
 }
 bool causal=edgeOnly>100&&outside==0;[guards addObject:@{@"check":@"exteriorOnlyMutationAffectsGlassWithSameROIPixels",@"pass":@(causal),@"interiorChangedOver1":@(interior),@"changedPixelsWhereParentHasNoExteriorResponse":@(edgeOnly),@"outsideShapeMaxByteDelta":@(outside),@"maxInteriorByteDelta":@(maxD)}];
 bool zeroPass=maximum(za,pa)<=1;[guards addObject:@{@"check":@"sameLeaseForceZeroEdgeWeightReturnsParent",@"pass":@(zeroPass),@"maxByteDelta":@(maximum(za,pa)),@"noEdgeTapsExecutedByZeroWeightBranch":@YES}];
 if(!save(@"causal-parent-red-exterior.png",pa)||!save(@"causal-parent-blue-exterior.png",pb)||!save(@"causal-edge-red-exterior.png",ea)||!save(@"causal-edge-blue-exterior.png",eb))return false;
 bool all=causal&&zeroPass;
 // The actual zero-pad contract disables the new path on a detailed source.
 NSData *source=[NSData dataWithContentsOfFile:[inputs stringByAppendingPathComponent:@"botanical-228.bgra"]];if(source.length!=S*S*4)return false;
 std::vector<uint8_t> crop(size);const uint8_t *raw=(const uint8_t *)source.bytes;for(NSUInteger y=0;y<T;y++)memcpy(crop.data()+y*T*4,raw+((y+O)*S+O)*4,T*4);
 auto tc=textureFor(crop,T);auto cc=contract(T,NO);LGLocalButtonUniforms uc={};if(!tc||!LGLocalButtonBuildUniforms(&cc,&state,T,T,3,true,&uc)||uc.buttonSourceOverscanEnabled!=0)return false;
 auto cp=Render(device,queue,parent,sampler,tc,&uc,sizeof uc,T,T),ce=Render(device,queue,candidate,sampler,tc,&uc,sizeof uc,T,T);bool noPad=maximum(cp,ce)==0;
 [guards addObject:@{@"check":@"actualNoOverscanSourceDetailedByteIdentity",@"pass":@(noPad),@"maxByteDelta":@(maximum(cp,ce)),@"realContractPaddingPoints":@0}];all=all&&noPad;
 // A valid1pt captured margin is insufficient at a named right-edge pixel.
 const NSUInteger N=138;std::vector<uint8_t> limited(N*N*4);for(NSUInteger y=0;y<N;y++)for(NSUInteger x=0;x<N;x++){size_t k=(y*N+x)*4;limited[k]=(uint8_t)(x*255/(N-1));limited[k+1]=(uint8_t)(y*255/(N-1));limited[k+2]=70;limited[k+3]=255;}
 auto tl=textureFor(limited,N);auto cl=contract(N,YES);LGLocalButtonUniforms ul={};if(!tl||!LGLocalButtonBuildUniforms(&cl,&state,T,T,3,true,&ul))return false;
 auto lp=Render(device,queue,parent,sampler,tl,&ul,sizeof ul,T,T),le=Render(device,queue,candidate,sampler,tl,&ul,sizeof ul,T,T);if(lp.size()!=size||le.size()!=size)return false;
 size_t named=(66*T+130)*4;unsigned namedDelta=0;for(unsigned k=0;k<4;k++)namedDelta=std::max(namedDelta,(unsigned)abs((int)lp[named+k]-(int)le[named+k]));bool missing=namedDelta<=1;
 [guards addObject:@{@"check":@"insufficientRealCapturedMarginExactPrimaryFallback",@"pass":@(missing),@"namedTargetPixel":@[@130,@66],@"actualCapturedMarginTexels":@3,@"maxByteDeltaAtRejectedStencil":@(namedDelta),@"noClampedReplacementPixels":@YES}];all=all&&missing;
 // Full transparency, partial premultiplied constants and unmeasured neighbor
 // alpha must preserve transmitted coverage. No opaque matte or alpha lift.
 for(unsigned alpha:{0u,64u,128u,255u}){
  std::vector<uint8_t> constant(S*S*4);for(NSUInteger i=0;i<S*S;i++){constant[i*4]=0;constant[i*4+1]=(uint8_t)(alpha/4);constant[i*4+2]=(uint8_t)(alpha/2);constant[i*4+3]=(uint8_t)alpha;}
  auto t=textureFor(constant,S);auto p=Render(device,queue,parent,sampler,t,&u,sizeof u,T,T),e=Render(device,queue,candidate,sampler,t,&u,sizeof u,T,T);if(e.size()!=size||p.size()!=size)return false;
  unsigned delta=maximum(p,e),alphaDelta=0;for(size_t k=3;k<size;k+=4)alphaDelta=std::max(alphaDelta,(unsigned)abs((int)e[k]-(int)alpha));bool ok=delta<=1&&alphaDelta==0;
  [guards addObject:@{@"check":@"constantPremultipliedCaptureIdentity",@"inputAlphaByte":@(alpha),@"pass":@(ok),@"maxParentByteDelta":@(delta),@"maxTransmittedAlphaDelta":@(alphaDelta),@"notProviderOpaqueRuntimeAcceptance":@YES}];all=all&&ok;
 }
 std::vector<uint8_t> clearOutside=a;for(NSUInteger y=0;y<S;y++)for(NSUInteger x=0;x<S;x++)if(!(x>=O&&x<O+T&&y>=O&&y<O+T)){size_t k=(y*S+x)*4;for(unsigned j=0;j<4;j++)clearOutside[k+j]=0;}
 auto tt=textureFor(clearOutside,S);auto tp=Render(device,queue,parent,sampler,tt,&u,sizeof u,T,T),te=Render(device,queue,candidate,sampler,tt,&u,sizeof u,T,T);if(tp.size()!=size||te.size()!=size)return false;
 unsigned coverage=0;for(size_t k=3;k<size;k+=4)coverage=std::max(coverage,(unsigned)abs((int)te[k]-(int)tp[k]));bool transparentFallback=maximum(tp,te)<=1&&coverage==0;
 [guards addObject:@{@"check":@"transparentExteriorFallsBackWithoutBlackHaloOrAlphaLift",@"pass":@(transparentFallback),@"maxParentByteDelta":@(maximum(tp,te)),@"transmittedAlphaMaxDelta":@(coverage)}];all=all&&transparentFallback;
 NSDictionary *report=@{@"scope":@"Extra actual Mac GPU branch/alpha/source-causality controls; same primary optical map; not real environment or phone evidence",@"allGuardPass":@(all),@"zeroWeightControlShaderSHA256":BytesHash([zeroSource dataUsingEncoding:NSUTF8StringEncoding]),@"readbacks":records};
 NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];return all&&data&&[data writeToFile:[out stringByAppendingPathComponent:@"exterior-source-gpu-controls.json"] atomically:YES];
}

int main(void){@autoreleasepool{
 NSString *oldPath=NSProcessInfo.processInfo.environment[@"BASELINE_METAL"];
 NSString *newPath=NSProcessInfo.processInfo.environment[@"CANDIDATE_METAL"];
 NSString *inputs=NSProcessInfo.processInfo.environment[@"MATERIAL_INPUTS"];
 NSString *out=NSProcessInfo.processInfo.environment[@"MATERIAL_RESULTS"];
 if(!oldPath.length||!newPath.length||!inputs.length||!out.length)return 2;
 NSData *oldBytes=[NSData dataWithContentsOfFile:oldPath],*newBytes=[NSData dataWithContentsOfFile:newPath];
 if(!oldBytes.length||!newBytes.length)return 3;
 id<MTLDevice>device=MTLCreateSystemDefaultDevice();if(!device){puts("NOT_RUN: Mac runner has no Metal device");return 77;}
 id<MTLCommandQueue>queue=[device newCommandQueue];id<MTLRenderPipelineState>baselinePipeline=nil,candidatePipeline=nil;
 NSString *oldSource=[[NSString alloc]initWithData:oldBytes encoding:NSUTF8StringEncoding];NSString *newSource=[[NSString alloc]initWithData:newBytes encoding:NSUTF8StringEncoding];
 if(!MakePipeline(device,oldSource.UTF8String,MTLPixelFormatBGRA8Unorm_sRGB,&baselinePipeline)||!MakePipeline(device,newSource.UTF8String,MTLPixelFormatBGRA8Unorm_sRGB,&candidatePipeline))return 4;
 id<MTLRenderPipelineState>pipelines[2]={baselinePipeline,candidatePipeline};
 MTLSamplerDescriptor *sd=[MTLSamplerDescriptor new];sd.minFilter=sd.magFilter=MTLSamplerMinMagFilterLinear;sd.sAddressMode=sd.tAddressMode=MTLSamplerAddressModeClampToEdge;id<MTLSamplerState>sampler=[device newSamplerStateWithDescriptor:sd];
 NSString *png=[out stringByAppendingPathComponent:@"pngs"];[[NSFileManager defaultManager]createDirectoryAtPath:png withIntermediateDirectories:YES attributes:nil error:nil];NSMutableArray *records=[NSMutableArray array],*guards=[NSMutableArray array],*timings=[NSMutableArray array];BOOL all=YES;
 constexpr NSUInteger T=132,S=228,O=48;const size_t bytes=T*T*4;
 for(NSString *scene in @[@"botanical",@"grid",@"black",@"gray",@"white"]){
  std::vector<uint8_t>source(S*S*4);
  if([scene isEqual:@"botanical"]||[scene isEqual:@"grid"]){NSData *d=[NSData dataWithContentsOfFile:[inputs stringByAppendingPathComponent:[scene stringByAppendingString:@"-228.bgra"]]];if(d.length!=source.size())return 5;memcpy(source.data(),d.bytes,d.length);}
  else{uint8_t value=[scene isEqual:@"black"]?0:([scene isEqual:@"white"]?255:128);for(size_t k=0;k<S*S;k++){source[k*4]=source[k*4+1]=source[k*4+2]=value;source[k*4+3]=255;}}
  std::vector<uint8_t>roi(bytes);for(NSUInteger y=0;y<T;y++)memcpy(roi.data()+y*T*4,source.data()+((y+O)*S+O)*4,T*4);
  MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB width:S height:S mipmapped:NO];td.usage=MTLTextureUsageShaderRead;td.storageMode=MTLStorageModeShared;id<MTLTexture>texture=[device newTextureWithDescriptor:td];[texture replaceRegion:MTLRegionMake2D(0,0,S,S) mipmapLevel:0 withBytes:source.data() bytesPerRow:S*4];
  NSString *sourceName=[NSString stringWithFormat:@"%@-actual-input-roi.png",scene];if(!SaveReadback([png stringByAppendingPathComponent:sourceName],roi,T,T))return 6;
  [records addObject:@{@"scene":scene,@"variant":@"inputROI",@"file":sourceName,@"BGRA_SHA256":PixelSHA(roi),@"PNG_SHA256":BytesHash([NSData dataWithContentsOfFile:[png stringByAppendingPathComponent:sourceName]]),@"sourceFullBGRA_SHA256":PixelSHA(source),@"isMaterialRender":@NO}];
  LGLocalButtonSourceContract c={};c.sourceRectInOwnerPoints=CGRectMake(-16,-16,76,76);c.targetRectInOwnerPoints=CGRectMake(0,0,44,44);c.textureWidth=c.textureHeight=S;c.pixelFormat=81;c.pointScale=3;c.targetGeometryGeneration=1;c.sourceOverscanEnabled=true;
  NSArray *phases=@[@"idle",@"leftContact",@"rightContact",@"release"];
  std::vector<uint8_t>idle[2];
  for(NSUInteger step=0;step<phases.count;step++){
   LGButtonOpticalState state={};state.eligible=true;state.geometryGeneration=1;state.phase=LGOpticalIdle;
   if(step==1||step==2){state.tracking=true;state.phase=LGOpticalTrackingInside;state.pressure=state.target=1;state.touchValid=true;state.touchX=step==1?.12f:.88f;state.touchY=.5f;}
   LGLocalButtonUniforms u={};if(!LGLocalButtonBuildUniforms(&c,&state,T,T,3,true,&u))return 7;
   if(step==0&&([scene isEqual:@"botanical"]||[scene isEqual:@"grid"])) {
    NSArray *bench=BenchmarkSampling(device,queue,baselinePipeline,candidatePipeline,sampler,texture,u);if(!bench)return 14;
    [timings addObject:@{@"scene":scene,@"statistics":bench,@"scope":@"Alternating same actual Mac GPU input; not A15 or system cost signoff"}];
   }
   for(unsigned variant=0;variant<2;variant++){
    auto pixels=Render(device,queue,pipelines[variant],sampler,texture,&u,sizeof u,T,T);if(pixels.size()!=bytes)return 8;
    if(step==0)idle[variant]=pixels;
    bool phaseIdentity=step!=3||pixels==idle[variant];bool outside=true;unsigned outsideMax=0;
    for(NSUInteger y=0;y<T;y++)for(NSUInteger x=0;x<T;x++){double dx=x+.5-T*.5,dy=y+.5-T*.5;if(dx*dx+dy*dy>=66*66){size_t k=(y*T+x)*4;for(unsigned q=0;q<4;q++){unsigned delta=abs((int)pixels[k+q]-(int)roi[k+q]);outsideMax=std::max(outsideMax,delta);if(delta>1)outside=false;}}}
    bool uniformScene=![scene isEqual:@"botanical"]&&![scene isEqual:@"grid"];unsigned uniformMax=0;
    if(uniformScene)for(size_t k=0;k<bytes;k++)uniformMax=std::max(uniformMax,(unsigned)abs((int)pixels[k]-(int)roi[k]));
    bool passive=!uniformScene||uniformMax<=1;all=all&&phaseIdentity&&outside&&passive;
    NSString *name=[NSString stringWithFormat:@"%@-%@-%@.png",scene,variant?@"newCandidate":@"frozenBaseline",phases[step]];
    if(!SaveReadback([png stringByAppendingPathComponent:name],pixels,T,T))return 9;
    [records addObject:@{@"scene":scene,@"variant":variant?@"newCandidate":@"frozenBaseline",@"phase":phases[step],@"file":name,@"BGRA_SHA256":PixelSHA(pixels),@"PNG_SHA256":BytesHash([NSData dataWithContentsOfFile:[png stringByAppendingPathComponent:name]]),@"sourceFullBGRA_SHA256":PixelSHA(source),@"actualCompletedReadback":@YES,@"isMaterialRender":@YES,@"uniformBytes":@(sizeof u),@"uniformBGRAIsSRGB":@YES}];
    [guards addObject:@{@"scene":scene,@"variant":@(variant),@"phase":phases[step],@"releaseEqualsActualIdle":@(phaseIdentity),@"shapeOutsideSourcePreserved":@(outside),@"outsideDeltaMax":@(outsideMax),@"uniformSourcePassive":@(passive),@"uniformSourceMaxByteDelta":@(uniformMax)}];
   }
  }
  LGButtonOpticalState noTouch={};noTouch.eligible=true;noTouch.geometryGeneration=1;LGLocalButtonUniforms neutral={};if(!LGLocalButtonBuildUniforms(&c,&noTouch,T,T,3,true,&neutral))return 10;neutral.glassThickness=0;
  for(unsigned variant=0;variant<2;variant++){auto zero=Render(device,queue,pipelines[variant],sampler,texture,&neutral,sizeof neutral,T,T);unsigned max=0;if(zero.size()!=bytes)return 11;for(size_t k=0;k<bytes;k++)max=std::max(max,(unsigned)abs((int)zero[k]-(int)roi[k]));all=all&&max<=1;[guards addObject:@{@"scene":scene,@"variant":@(variant),@"check":@"zeroThicknessSourceIdentity",@"maxByteDelta":@(max),@"pass":@(max<=1)}];}
 }
 if(!EdgeSourceGuards(device,queue,baselinePipeline,candidatePipeline,sampler,newSource,inputs,out,guards))return 15;
 NSDictionary *report=@{@"scope":@"Same owned inputs and production240B uniforms; completed macOS Metal offscreen readbacks, NOT iPhone or system-host visual acceptance",@"oldMSLSHA256":BytesHash(oldBytes),@"newMSLSHA256":BytesHash(newBytes),@"actualMetalDeviceName":device.name?:@"unknown",@"targetPixels":@132,@"sourcePixels":@228,@"targetOriginPixels":@[@48,@48],@"allSafetyGuards":@(all),@"records":records,@"guards":guards,@"macOffscreenCommandBenchmarks":timings,@"visualGoal":@"NOT_ACCEPTED_AUTOMATICALLY: parent must inspect actual images",@"systemRuntime":@"NOT_RUN",@"trueUIKitInputForThisMacTest":@NO};
 NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];if(!data||![data writeToFile:[out stringByAppendingPathComponent:@"material-ab-readbacks.json"] atomically:YES])return 12;
 printf("%s material A/B same-input Metal readbacks; images=%lu, finite/passive/zero-thickness/shape-outside guards only; visual acceptance is separate\n",all?"PASS":"FAIL",(unsigned long)records.count);
 return all?0:13;
}}
