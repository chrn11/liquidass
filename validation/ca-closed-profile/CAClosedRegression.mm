// CA-closed profile GPU regression harness. The only image-producing work in this
// program is performed by Metal on a real MTLDevice. CPU code makes deterministic
// BGRA inputs, reads back Metal outputs, compares bytes, and writes artifacts.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#import <simd/simd.h>
#include <initializer_list>
#include <math.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#if !defined(LG_CA_CLOSED_PROFILE_COMPILED) || LG_CA_CLOSED_PROFILE_COMPILED != 1
#error "The regression harness must compile the real CA208B profile (macro exactly 1)."
#endif
#include "LGCAClosedProfileShaderSource.h"
#include "LGCAClosedProfilePolicy.h"
#include "LGCAClosedProfileRuntime.h" // single-TU ObjC++ implementation

// Frozen normal149 208-byte Uniforms prefix; no contact/overscan extension.
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
} LGCAClosedTestUniforms;
static_assert(sizeof(LGCAClosedTestUniforms)==208, "normal149 Uniforms ABI must be 208 bytes");
static_assert(offsetof(LGCAClosedTestUniforms, wallpaperOrigin)==72, "Uniforms offset drift");
static_assert(offsetof(LGCAClosedTestUniforms, shapeOrigin)==120, "Uniforms offset drift");
static_assert(offsetof(LGCAClosedTestUniforms, tintColor)==160, "Uniforms offset drift");
static_assert(offsetof(LGCAClosedTestUniforms, buttonCandidate)==176, "Uniforms offset drift");
static_assert(offsetof(LGCAClosedTestUniforms, buttonCandidateCenter)==184, "Uniforms offset drift");
static_assert(offsetof(LGCAClosedTestUniforms, buttonCandidateRendererScale)==200, "Uniforms offset drift");

struct DiffStats {
    uint64_t differentBytes=0, differentPixels=0, alphaDifferentBytes=0, rgbDifferentBytes=0;
    unsigned maxByteDiff=0;
};
struct RenderResult {
    std::vector<uint8_t> pixels;
    __strong NSString *commandStatus=nil;
    __strong NSString *errorMessage=nil;
    __strong LGCAClosedAuditLease *lease=nil;
    BOOL usedProfile=NO, auditFlagAvailable=NO;
    uint32_t auditFlag=UINT32_MAX;
};
struct CaseResult {
    std::vector<uint8_t> oldPixels, profilePixels;
    __strong NSMutableDictionary *record=nil;
};

static NSString *Path(NSString *root, NSString *child) { return [root stringByAppendingPathComponent:child]; }
static bool MakeDir(NSString *path) {
    NSError *e=nil;
    return [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&e] ||
           [[NSFileManager defaultManager] fileExistsAtPath:path];
}
static bool WriteBytes(NSString *path, const void *bytes, size_t length) {
    NSData *d=[NSData dataWithBytes:bytes length:length]; NSError *e=nil;
    return [d writeToFile:path options:NSDataWritingAtomic error:&e];
}
static bool WriteText(NSString *path, NSString *text) {
    NSError *e=nil; return [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&e];
}
static bool WriteJSON(NSString *path, id object) {
    NSError *e=nil; NSData *d=[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&e];
    return d && [d writeToFile:path options:NSDataWritingAtomic error:&e];
}
static NSString *HexSHA256(const void *bytes, size_t length) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(bytes,(CC_LONG)length,digest);
    static const char hex[]="0123456789abcdef"; char out[65];
    for (unsigned i=0;i<sizeof(digest);++i) { out[2*i]=hex[digest[i]>>4]; out[2*i+1]=hex[digest[i]&15]; }
    out[64]=0; return [NSString stringWithUTF8String:out];
}
static NSString *SHAData(NSData *data) { return HexSHA256(data.bytes,data.length); }
static NSString *SHAString(const char *s) { return HexSHA256(s,strlen(s)); }
static NSString *KernelSHA256(const char *source) {
    const char *key="LGCAAuditOpaque"; const char *p=strstr(source,key); if (!p) return @"MISSING";
    const char *k=p; while (k>source && strncmp(k,"kernel",6)!=0) --k;
    if (strncmp(k,"kernel",6)!=0) return @"MISSING";
    const char *open=strchr(p,'{'); if (!open) return @"MISSING";
    unsigned depth=0; const char *end=nullptr;
    for (const char *q=open;*q;++q) { if (*q=='{') ++depth; else if (*q=='}' && --depth==0) { end=q+1; break; } }
    return end ? HexSHA256(k,(size_t)(end-k)) : @"MISSING";
}
static NSString *StatusName(MTLCommandBufferStatus status) {
    switch (status) {
        case MTLCommandBufferStatusNotEnqueued:return @"notEnqueued";
        case MTLCommandBufferStatusEnqueued:return @"enqueued";
        case MTLCommandBufferStatusCommitted:return @"committed";
        case MTLCommandBufferStatusScheduled:return @"scheduled";
        case MTLCommandBufferStatusCompleted:return @"completed";
        case MTLCommandBufferStatusError:return @"error";
    }
    return @"unknown";
}
static NSDictionary *Pool(id runtime) { return runtime ? [runtime poolSnapshot] : @{}; }
static bool SavePNG(NSString *path, const uint8_t *bytes, NSUInteger width, NSUInteger height) {
    if (!bytes || !width || !height) return false;
    CFDataRef data=CFDataCreate(kCFAllocatorDefault,bytes,(CFIndex)(width*height*4));
    if (!data) return false;
    CGDataProviderRef provider=CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGBitmapInfo info=(CGBitmapInfo)(kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst);
    CGImageRef image=provider&&cs?CGImageCreate(width,height,8,32,width*4,cs,info,provider,NULL,false,kCGRenderingIntentDefault):NULL;
    NSURL *url=[NSURL fileURLWithPath:path];
    CGImageDestinationRef dest=image?CGImageDestinationCreateWithURL((__bridge CFURLRef)url,CFSTR("public.png"),1,NULL):NULL;
    bool finalized=false;
    if (dest) { CGImageDestinationAddImage(dest,image,NULL); finalized=CGImageDestinationFinalize(dest); }
    if (dest) CFRelease(dest); if (image) CGImageRelease(image); if (cs) CGColorSpaceRelease(cs);
    if (provider) CGDataProviderRelease(provider); CFRelease(data); return finalized;
}
static std::vector<uint8_t> MakeGrid(NSUInteger w, NSUInteger h) {
    std::vector<uint8_t> v(w*h*4);
    for (NSUInteger y=0;y<h;++y) for (NSUInteger x=0;x<w;++x) {
        unsigned cell=((x/8)+(y/8))&1u; unsigned edge=((x%8)==0 || (y%8)==0)?18u:0u;
        uint8_t grey=(uint8_t)(cell?174u:70u); size_t i=(y*w+x)*4;
        v[i+0]=(uint8_t)std::max(0,(int)grey-(int)edge); v[i+1]=grey;
        v[i+2]=(uint8_t)std::min(255,(int)grey+(int)edge); v[i+3]=255;
    }
    return v;
}
static void DamagePixel(std::vector<uint8_t>& v, NSUInteger w, NSUInteger x, NSUInteger y, uint8_t alpha, unsigned salt) {
    size_t i=(y*w+x)*4; v[i+0]=(uint8_t)(221u-salt%41u); v[i+1]=(uint8_t)(73u+salt%91u);
    v[i+2]=(uint8_t)(149u+salt%83u); v[i+3]=alpha;
}
static LGCAClosedTestUniforms Uniforms(NSUInteger sw, NSUInteger sh, NSUInteger ow, NSUInteger oh, float candidate, float glare) {
    LGCAClosedTestUniforms u={}; float w=(float)sw,h=(float)sh,shortest=fminf(w,h);
    u.resolution=simd_make_float2(w,h); u.outputResolution=simd_make_float2((float)ow,(float)oh);
    u.screenResolution=simd_make_float2(w,h); u.cardOrigin=simd_make_float2(0,0);
    u.wallpaperResolution=simd_make_float2(w,h); u.lensOrigin=simd_make_float2(w*0.5f,h*0.5f);
    u.radius=0.5f*shortest; u.bezelWidth=fminf(16.0f*(shortest/44.0f),shortest*0.5f); u.glassThickness=108.0f;
    u.refractionScale=2.0f; u.refractiveIndex=1.60f; u.wallpaperOrigin=simd_make_float2(0,0);
    u.samplingTransformX=simd_make_float2(1,0); u.samplingTransformY=simd_make_float2(0,1);
    u.samplingTransformOffset=simd_make_float2(0,0); u.samplingOrientation=1.0f; u.backdropZoom=1.0f;
    u.shapeScale=1.0f; u.shapeOrigin=simd_make_float2(0,0); u.shapeSize=simd_make_float2(0,0);
    u.useGlyphMask=0.0f; u.dispersionStrength=0.0f; u.fresnelGlareStrength=glare;
    u.borderWidthPixels=2.0f; u.tintColor=simd_make_float4(0,0,0,0);
    LGButtonOpticsGeometry g={};
    if (!LGButtonCandidateBuildGeometry(w,h,(float)ow,(float)oh,3.0f,&g)) abort();
    u.buttonCandidate=candidate; u.buttonCandidateMaxOffset=LGButtonCandidateMaxDisplacement(w,h);
    u.buttonCandidateCenter=simd_make_float2(g.centerX,g.centerY);
    u.buttonCandidatePointScale=fminf(g.pointScaleX,g.pointScaleY);
    u.buttonCandidateCornerRadius=g.cornerRadius;u.radius=g.cornerRadius;
    u.buttonCandidateRendererScale=g.rendererScale; return u;
}
static id<MTLTexture> MakeSource(id<MTLDevice> device, NSUInteger w, NSUInteger h, const std::vector<uint8_t>& pixels, MTLPixelFormat format=MTLPixelFormatBGRA8Unorm_sRGB) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
    d.usage=MTLTextureUsageShaderRead; d.storageMode=MTLStorageModeShared;
    id<MTLTexture> t=[device newTextureWithDescriptor:d]; if (!t) return nil;
    [t replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:pixels.data() bytesPerRow:w*4]; return t;
}
static id<MTLTexture> MakeColorTarget(id<MTLDevice> device, NSUInteger w, NSUInteger h) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB width:w height:h mipmapped:NO];
    d.usage=MTLTextureUsageRenderTarget; d.storageMode=MTLStorageModePrivate;
    return [device newTextureWithDescriptor:d];
}
static id<MTLTexture> MakeReadback(id<MTLDevice> device, NSUInteger w, NSUInteger h) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB width:w height:h mipmapped:NO];
    d.usage=MTLTextureUsageUnknown; d.storageMode=MTLStorageModeShared;
    return [device newTextureWithDescriptor:d];
}
static id<MTLTexture> MakeGlyphMask(id<MTLDevice> device) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:1 height:1 mipmapped:NO];
    d.usage=MTLTextureUsageShaderRead; d.storageMode=MTLStorageModeShared;
    id<MTLTexture> t=[device newTextureWithDescriptor:d]; uint8_t zero=0;
    if (t) [t replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:&zero bytesPerRow:1]; return t;
}
static RenderResult Draw(id<MTLDevice> device, id<MTLCommandQueue> queue,
                         LGCAClosedProfileRuntime *runtime, id<MTLRenderPipelineState> oldPipeline,
                         id<MTLTexture> source, id<MTLTexture> glyph, const LGCAClosedTestUniforms& u,
                         NSUInteger outW, NSUInteger outH, bool tryProfile, id<MTLBuffer> faultToken=nil) {
    RenderResult r; id<MTLTexture> target=MakeColorTarget(device,outW,outH), readback=MakeReadback(device,outW,outH);
    id<MTLCommandBuffer> cb=[queue commandBuffer];
    if (!target||!readback||!cb) { r.errorMessage=@"texture/command allocation failed"; return r; }
    id<MTLRenderPipelineState> pipeline=oldPipeline;
    if (faultToken) { pipeline=runtime.renderPipeline; r.usedProfile=YES; }
    else if (tryProfile) {
        r.lease=[runtime encodeAuditForSource:source command:cb];
        if (r.lease) { pipeline=runtime.renderPipeline; r.usedProfile=YES; }
    }
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=target; pass.colorAttachments[0].loadAction=MTLLoadActionClear;
    pass.colorAttachments[0].storeAction=MTLStoreActionStore; pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
    id<MTLRenderCommandEncoder> enc=[cb renderCommandEncoderWithDescriptor:pass];
    if (!enc) { r.errorMessage=@"render encoder allocation failed"; [cb commit]; [cb waitUntilCompleted]; r.commandStatus=StatusName(cb.status); return r; }
    [enc setRenderPipelineState:pipeline];
    MTLViewport viewport={0.0,0.0,(double)outW,(double)outH,0.0,1.0}; [enc setViewport:viewport];
    [enc setCullMode:MTLCullModeNone]; [enc setFrontFacingWinding:MTLWindingClockwise];
    [enc setFragmentTexture:source atIndex:0]; [enc setFragmentTexture:glyph atIndex:1];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
    if (r.usedProfile) [enc setFragmentBuffer:faultToken?:r.lease.buffer offset:0 atIndex:1];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [enc endEncoding];
    id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
    if (!blit) { r.errorMessage=@"readback blit encoder allocation failed"; [cb commit]; [cb waitUntilCompleted]; r.commandStatus=StatusName(cb.status); return r; }
    [blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
              sourceSize:MTLSizeMake(outW,outH,1) toTexture:readback destinationSlice:0 destinationLevel:0
       destinationOrigin:MTLOriginMake(0,0,0)]; [blit endEncoding];
    [cb commit]; [cb waitUntilCompleted]; r.commandStatus=StatusName(cb.status);
    if (cb.status!=MTLCommandBufferStatusCompleted) {
        r.errorMessage=cb.error.localizedDescription ?: @"Metal command did not complete"; return r;
    }
    r.pixels.resize(outW*outH*4);
    [readback getBytes:r.pixels.data() bytesPerRow:outW*4 fromRegion:MTLRegionMake2D(0,0,outW,outH) mipmapLevel:0];
    id<MTLBuffer> token=faultToken?:r.lease.buffer;
    if (token.contents) { memcpy(&r.auditFlag,token.contents,sizeof(r.auditFlag)); r.auditFlagAvailable=YES; }
    else if (r.lease) r.errorMessage=@"audit lease buffer is not CPU-readable after completion";
    return r;
}
static DiffStats Compare(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b) {
    DiffStats d; if (a.size()!=b.size()) { d.differentBytes=UINT64_MAX; d.maxByteDiff=255; return d; }
    for (size_t i=0;i<a.size();++i) { unsigned n=(unsigned)std::abs((int)a[i]-(int)b[i]); if (n) { ++d.differentBytes; d.maxByteDiff=std::max(d.maxByteDiff,n); if ((i&3u)==3u) ++d.alphaDifferentBytes; else ++d.rgbDifferentBytes; } }
    for (size_t i=0;i<a.size();i+=4) if (a[i]!=b[i]||a[i+1]!=b[i+1]||a[i+2]!=b[i+2]||a[i+3]!=b[i+3]) ++d.differentPixels;
    return d;
}
static bool IsTransparentBorder(const std::vector<uint8_t>& p, NSUInteger w, NSUInteger h) {
    for (NSUInteger y=0;y<h;++y) for (NSUInteger x=0;x<w;++x) if (x==0||y==0||x+1==w||y+1==h) {
        size_t i=(y*w+x)*4; if (p[i]||p[i+1]||p[i+2]||p[i+3]) return false;
    } return true;
}
static NSNumber *N(uint64_t v) { return [NSNumber numberWithUnsignedLongLong:v]; }
static NSString *CaseFile(NSString *root, NSString *leaf) { return Path(Path(root,@"json"),leaf); }
static CaseResult RunCase(NSString *outRoot, NSMutableArray *records, id<MTLDevice> device,
                          id<MTLCommandQueue> queue, LGCAClosedProfileRuntime *runtime,
                          id<MTLRenderPipelineState> oldPipeline, id<MTLTexture> glyph,
                          NSString *caseID, NSUInteger sw, NSUInteger sh, NSUInteger ow, NSUInteger oh,
                          const std::vector<uint8_t>& sourceBytes, LGCAClosedTestUniforms u,
                          bool expectAuditZero, NSString *expectDiff, bool expectProfileLease=YES) {
    CaseResult cr; id<MTLTexture> source=MakeSource(device,sw,sh,sourceBytes);
    NSData *srcData=[NSData dataWithBytes:sourceBytes.data() length:sourceBytes.size()];
    NSData *uniformData=[NSData dataWithBytes:&u length:sizeof(u)];
    NSDictionary *poolBefore=Pool(runtime);
    RenderResult old=Draw(device,queue,runtime,oldPipeline,source,glyph,u,ow,oh,false);
    RenderResult prof=Draw(device,queue,runtime,oldPipeline,source,glyph,u,ow,oh,true);
    NSDictionary *poolAfter=Pool(runtime); cr.oldPixels=std::move(old.pixels); cr.profilePixels=std::move(prof.pixels);
    DiffStats diff=Compare(cr.oldPixels,cr.profilePixels); bool commandsOK=[old.commandStatus isEqual:@"completed"]&&[prof.commandStatus isEqual:@"completed"];
    bool leaseOK=(prof.lease!=nil)==expectProfileLease;
    bool auditOK=!expectProfileLease || (prof.auditFlagAvailable && prof.auditFlag==(expectAuditZero?kLGCAOpaqueAcceptMagic:0u));
    bool imageOK=cr.oldPixels.size()==ow*oh*4 && cr.profilePixels.size()==ow*oh*4;
    bool pixelOK=expectDiff==nil || ([expectDiff isEqual:@"equal"]?diff.differentBytes==0:diff.differentBytes>0);
    bool ok=source&&commandsOK&&leaseOK&&auditOK&&imageOK&&pixelOK;
    NSString *stem=caseID; NSString *raw=Path(Path(outRoot,@"rawBGRA"),[stem stringByAppendingString:@".source.bgra"]);
    bool artifacts=WriteBytes(raw,sourceBytes.data(),sourceBytes.size());
    if (imageOK) {
        NSString *oldRaw=Path(Path(outRoot,@"rawBGRA"),[stem stringByAppendingString:@".old.bgra"]);
        NSString *profRaw=Path(Path(outRoot,@"rawBGRA"),[stem stringByAppendingString:@".profile.bgra"]);
        artifacts=WriteBytes(oldRaw,cr.oldPixels.data(),cr.oldPixels.size())&&WriteBytes(profRaw,cr.profilePixels.data(),cr.profilePixels.size())&&artifacts;
        artifacts=SavePNG(Path(Path(outRoot,@"PNG"),[stem stringByAppendingString:@".source.png"]),(const uint8_t*)sourceBytes.data(),sw,sh)&&artifacts;
        artifacts=SavePNG(Path(Path(outRoot,@"PNG"),[stem stringByAppendingString:@".old.png"]),cr.oldPixels.data(),ow,oh)&&artifacts;
        artifacts=SavePNG(Path(Path(outRoot,@"PNG"),[stem stringByAppendingString:@".profile.png"]),cr.profilePixels.data(),ow,oh)&&artifacts;
    }
    if (expectDiff && [expectDiff isEqual:@"different"]) ok=ok&&diff.differentBytes>0;
    if (expectDiff && [expectDiff isEqual:@"equal"]) ok=ok&&diff.differentBytes==0;
    if (expectProfileLease && !prof.auditFlagAvailable) ok=NO;
    if (expectProfileLease && prof.auditFlagAvailable && prof.auditFlag!=(expectAuditZero?kLGCAOpaqueAcceptMagic:0u)) ok=NO;
    cr.record=[@{
        @"case":caseID,@"status":(ok&&artifacts)?@"PASS":@"FAIL",
        @"sourceSHA256":SHAData(srcData),@"sourceBytes":@(srcData.length),
        @"uniformBytes":@(sizeof(u)),@"uniformBase64":[uniformData base64EncodedStringWithOptions:0],@"uniformSHA256":SHAData(uniformData),
        @"profileShaderSHA256":SHAString(kLGCAClosedProfileMSL),@"profileKernelSHA256":KernelSHA256(kLGCAClosedProfileMSL),
        @"baselineShaderSHA256":SHAString(kLGCAClosedBaselineMSL),
        @"realCommandStatus":@{@"old":old.commandStatus?:@"notCreated",@"profile":prof.commandStatus?:@"notCreated"},
        @"oldCommandError":old.errorMessage?:[NSNull null],@"profileCommandError":prof.errorMessage?:[NSNull null],
        @"auditLeaseAccepted":@(prof.lease!=nil),@"profilePipelineUsed":@(prof.usedProfile),
        @"auditFlag":prof.auditFlagAvailable?@(prof.auditFlag):[NSNull null],@"expectedAuditFlag":expectAuditZero?@(kLGCAOpaqueAcceptMagic):@0,
        @"poolBefore":poolBefore,@"poolAfter":poolAfter,
        @"oldVsProfile":@{@"maxByteDiff":@(diff.maxByteDiff),@"differentByteCount":N(diff.differentBytes),@"differentPixelCount":N(diff.differentPixels),@"rgbDifferentByteCount":N(diff.rgbDifferentBytes),@"alphaDifferentByteCount":N(diff.alphaDifferentBytes)},
        @"expectedDiff":expectDiff?:@"observed",@"assertions":@{@"commandsCompleted":@(commandsOK),@"leaseExpectation":@(leaseOK),@"auditFlagExpectation":@(auditOK),@"outputDimensions":@(imageOK),@"pixelExpectation":@(pixelOK),@"artifactsWritten":@(artifacts)},
        @"files":@{@"sourceRawBGRA":[stem stringByAppendingString:@".source.bgra"],@"oldRawBGRA":[stem stringByAppendingString:@".old.bgra"],@"profileRawBGRA":[stem stringByAppendingString:@".profile.bgra"],@"pngPrefix":stem}
    } mutableCopy]; [records addObject:cr.record]; return cr;
}
static id<MTLRenderPipelineState> MakeBaselinePipeline(id<MTLDevice> device, NSError **outError) {
    NSString *src=[NSString stringWithUTF8String:kLGCAClosedBaselineMSL]; if (!src) return nil;
    id<MTLLibrary> lib=[device newLibraryWithSource:src options:nil error:outError]; if (!lib) return nil;
    id<MTLFunction> vertex=[lib newFunctionWithName:@"liquidGlassVertex"];
    id<MTLFunction> fragment=[lib newFunctionWithName:@"liquidGlassFragment"];
    if (!vertex||!fragment) return nil;
    MTLRenderPipelineDescriptor *p=[MTLRenderPipelineDescriptor new]; p.label=@"normal149 frozen baseline exact bytes";
    p.vertexFunction=vertex; p.fragmentFunction=fragment; p.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm_sRGB;
    p.colorAttachments[0].blendingEnabled=NO;
    return [device newRenderPipelineStateWithDescriptor:p error:outError];
}
static bool BorderEqual(const std::vector<uint8_t>& a,const std::vector<uint8_t>& b,NSUInteger w,NSUInteger h) {
    if (a.size()!=b.size()) return false;
    for (NSUInteger y=0;y<h;++y) for (NSUInteger x=0;x<w;++x) if (x==0||y==0||x+1==w||y+1==h) {
        size_t i=(y*w+x)*4; for (unsigned c=0;c<4;++c) if (a[i+c]!=b[i+c]) return false;
    } return true;
}
#include "CAClosedAuditFaultTests.h"
static bool TestFormat80(NSString *outRoot,id<MTLDevice> device,id<MTLCommandQueue> queue,LGCAClosedProfileRuntime *runtime) {
    NSUInteger w=132,h=132; std::vector<uint8_t> pixels=MakeGrid(w,h);
    id<MTLTexture> source=MakeSource(device,w,h,pixels,MTLPixelFormatBGRA8Unorm);
    id<MTLCommandBuffer> cb=[queue commandBuffer]; NSDictionary *before=Pool(runtime);
    LGCAClosedAuditLease *lease=(source&&cb)?[runtime encodeAuditForSource:source command:cb]:nil;
    if (cb) { [cb commit]; [cb waitUntilCompleted]; }
    NSString *status=cb?StatusName(cb.status):@"notCreated"; NSDictionary *after=Pool(runtime);
    bool ok=source&&cb&&lease==nil&&[status isEqual:@"completed"];
    LGCAClosedTestUniforms u=Uniforms(w,h,w,h,2.0f,0.0f); NSData *uniformData=[NSData dataWithBytes:&u length:sizeof(u)];
    NSMutableDictionary *r=[@{@"case":@"reject-format-80",@"status":ok?@"PASS":@"FAIL",
        @"pixelFormat":@(MTLPixelFormatBGRA8Unorm),@"pixelFormatName":@"BGRA8Unorm (non-sRGB)",
        @"sourceSHA256":SHAData([NSData dataWithBytes:pixels.data() length:pixels.size()]),
        @"uniformBytes":@(sizeof(u)),@"uniformBase64":[uniformData base64EncodedStringWithOptions:0],@"uniformSHA256":SHAData(uniformData),@"uniformPassedToAuditAPI":@NO,
        @"profileShaderSHA256":SHAString(kLGCAClosedProfileMSL),@"profileKernelSHA256":KernelSHA256(kLGCAClosedProfileMSL),@"baselineShaderSHA256":SHAString(kLGCAClosedBaselineMSL),
        @"oldVsProfile":[NSNull null],@"auditFlag":[NSNull null],
        @"realCommandStatus":status,@"runtimeReturnedNil":@(lease==nil),@"poolBefore":before,@"poolAfter":after,
        @"assertions":@{@"notAccepted":@(lease==nil),@"commandCompleted":@([status isEqual:@"completed"]),@"formatIsNotSRGB":@(MTLPixelFormatBGRA8Unorm!=MTLPixelFormatBGRA8Unorm_sRGB)}}
        mutableCopy];
    bool written=WriteJSON(CaseFile(outRoot,@"reject-format-80.json"),r);
    if (!written) { r[@"status"]=@"FAIL"; WriteJSON(CaseFile(outRoot,@"reject-format-80.json"),r); }
    return ok&&written;
}
static bool TestPool(NSString *outRoot,id<MTLDevice> device,id<MTLCommandQueue> queue,LGCAClosedProfileRuntime *runtime) {
    NSUInteger w=132,h=132; std::vector<uint8_t> pixels=MakeGrid(w,h); id<MTLTexture> source=MakeSource(device,w,h,pixels);
    LGCAClosedTestUniforms u=Uniforms(w,h,w,h,2.0f,0.0f); NSData *uniformData=[NSData dataWithBytes:&u length:sizeof(u)];
    NSMutableArray<id<MTLCommandBuffer>> *commands=[NSMutableArray array]; NSMutableArray<LGCAClosedAuditLease *> *leases=[NSMutableArray array];
    NSMutableArray *accepted=[NSMutableArray array]; NSMutableArray *snapshots=[NSMutableArray array];
    for (unsigned i=0;i<4;++i) {
        id<MTLCommandBuffer> cb=[queue commandBuffer]; LGCAClosedAuditLease *lease=(cb&&source)?[runtime encodeAuditForSource:source command:cb]:nil;
        if (cb) [commands addObject:cb]; [accepted addObject:@(lease!=nil)];
        if (lease) [leases addObject:lease]; [snapshots addObject:Pool(runtime)];
    }
    NSDictionary *full=Pool(runtime);
    // The first three buffers are deliberately still uncommitted here. This is a
    // bounded-slot accounting test, not a GPU-concurrency or throughput test.
    for (id<MTLCommandBuffer> cb in commands) [cb commit];
    for (id<MTLCommandBuffer> cb in commands) [cb waitUntilCompleted];
    for (unsigned spin=0;spin<500 && [[Pool(runtime) objectForKey:@"busyCount"] unsignedIntegerValue]!=0;++spin)
        [NSThread sleepForTimeInterval:0.001];
    NSDictionary *empty=Pool(runtime);
    id<MTLCommandBuffer> retry=[queue commandBuffer]; LGCAClosedAuditLease *retryLease=retry?[runtime encodeAuditForSource:source command:retry]:nil;
    NSDictionary *retryBusy=Pool(runtime); if (retry) { [retry commit]; [retry waitUntilCompleted]; }
    for (unsigned spin=0;spin<500 && [[Pool(runtime) objectForKey:@"busyCount"] unsignedIntegerValue]!=0;++spin)
        [NSThread sleepForTimeInterval:0.001];
    NSDictionary *released=Pool(runtime);
    NSMutableArray *statuses=[NSMutableArray array]; for (id<MTLCommandBuffer> cb in commands) [statuses addObject:StatusName(cb.status)];
    bool firstThree=accepted.count==4&&[accepted[0] boolValue]&&[accepted[1] boolValue]&&[accepted[2] boolValue];
    bool fourthNil=accepted.count==4&&![accepted[3] boolValue];
    bool counts=[[full objectForKey:@"busyCount"] unsignedIntegerValue]==3&&[[full objectForKey:@"slotCount"] unsignedIntegerValue]==3;
    bool returned=[[empty objectForKey:@"busyCount"] unsignedIntegerValue]==0&&[[released objectForKey:@"busyCount"] unsignedIntegerValue]==0;
    bool retryOK=retryLease!=nil&&[[retryBusy objectForKey:@"busyCount"] unsignedIntegerValue]==1;
    bool commandsOK=YES; for (NSString *s in statuses) if (![s isEqual:@"completed"]) commandsOK=NO;
    if (retry && retry.status!=MTLCommandBufferStatusCompleted) commandsOK=NO;
    bool ok=source&&firstThree&&fourthNil&&counts&&returned&&retryOK&&commandsOK;
    NSDictionary *r=@{@"case":@"pool-three-slots",@"status":ok?@"PASS":@"FAIL",
        @"sourceSHA256":SHAData([NSData dataWithBytes:pixels.data() length:pixels.size()]),@"uniformBytes":@(sizeof(u)),@"uniformBase64":[uniformData base64EncodedStringWithOptions:0],@"uniformSHA256":SHAData(uniformData),@"uniformPassedToAuditAPI":@NO,
        @"profileShaderSHA256":SHAString(kLGCAClosedProfileMSL),@"profileKernelSHA256":KernelSHA256(kLGCAClosedProfileMSL),@"baselineShaderSHA256":SHAString(kLGCAClosedBaselineMSL),@"oldVsProfile":[NSNull null],
        @"fourAcquireResults":accepted,@"snapshotAfterEachAcquire":snapshots,@"snapshotAtThreeBusy":full,
        @"snapshotAfterCompletion":empty,@"snapshotAfterReacquire":retryBusy,@"snapshotAfterReacquireCompletion":released,
        @"realCommandStatus":@{@"firstFour":statuses,@"reacquire":retry?StatusName(retry.status):@"notCreated"},
        @"auditFlagsAfterCompletion":@"per-slot buffer values checked below when readable",
        @"notPerformanceMeasurement":@YES,@"scopeNote":@"Three uncommitted command buffers test bounded lease slots only; they do not establish GPU concurrency or performance.",
        @"assertions":@{@"firstThreeAccepted":@(firstThree),@"fourthRejected":@(fourthNil),@"busy3Of3":@(counts),@"slotsReturnOnCompletion":@(returned),@"slotCanBeReacquired":@(retryOK),@"allCommandsCompleted":@(commandsOK)}};
    // Audit flags for each of the first three and reacquire are CPU-readable shared uint32s after completion.
    NSMutableArray *flags=[NSMutableArray array]; BOOL flagsOK=YES;
    for (LGCAClosedAuditLease *l in leases) { uint32_t f=UINT32_MAX; if (l.buffer.contents) memcpy(&f,l.buffer.contents,4); else flagsOK=NO; [flags addObject:@(f)]; if (f!=kLGCAOpaqueAcceptMagic) flagsOK=NO; }
    if (retryLease) { uint32_t f=UINT32_MAX; if (retryLease.buffer.contents) memcpy(&f,retryLease.buffer.contents,4); else flagsOK=NO; [flags addObject:@(f)]; if (f!=kLGCAOpaqueAcceptMagic) flagsOK=NO; }
    NSMutableDictionary *final=[r mutableCopy]; final[@"auditFlagsAfterCompletion"]=flags;
    NSMutableDictionary *assertions=[r[@"assertions"] mutableCopy]; assertions[@"allAuditTokensAccepted"]=@(flagsOK); final[@"assertions"]=assertions;
    if (!flagsOK) { final[@"status"]=@"FAIL"; ok=NO; }
    bool written=WriteJSON(CaseFile(outRoot,@"pool-three-slots.json"),final);
    if (!written) { final[@"status"]=@"FAIL"; WriteJSON(CaseFile(outRoot,@"pool-three-slots.json"),final); }
    return ok&&written;
}
static bool WriteCaseReports(NSString *outRoot,NSArray *records) {
    bool ok=true; for (NSDictionary *r in records) {
        NSString *name=[NSString stringWithFormat:@"%@.json",r[@"case"]];
        ok=WriteJSON(CaseFile(outRoot,name),r)&&ok;
    } return ok;
}
static bool AllCaseRecordsPass(NSArray *records) {
    for (NSDictionary *r in records) if (![r[@"status"] isEqual:@"PASS"]) return false; return true;
}
static NSString *OutDirArg(int argc,const char **argv) {
    if (argc>1 && argv[1] && argv[1][0]) return [NSString stringWithUTF8String:argv[1]];
    return nil;
}
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        NSString *outRoot=OutDirArg(argc,argv);
        if (!outRoot) { fprintf(stderr,"usage: CAClosedRegression <outDir>\n"); return 2; }
        NSString *jsonDir=Path(outRoot,@"json"),*rawDir=Path(outRoot,@"rawBGRA"),*pngDir=Path(outRoot,@"PNG");
        if (!MakeDir(outRoot)||!MakeDir(jsonDir)||!MakeDir(rawDir)||!MakeDir(pngDir)) { fprintf(stderr,"cannot create output directories\n"); return 1; }
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        if (!device) {
            NSDictionary *notRun=@{@"schemaVersion":@1,@"status":@"NOT_RUN",@"reason":@"MTLCreateSystemDefaultDevice returned nil; no real Metal GPU is available.",
                @"exitCode":@77,@"device":@"unavailable",@"scope":@"No window, screen capture, CPU-rendered material, or fake Metal objects were used."};
            WriteJSON(CaseFile(outRoot,@"run.json"),notRun); WriteText(Path(outRoot,@"NOT_RUN.txt"),@"NOT_RUN: no Metal device; exit 77.\n");
            fprintf(stderr,"NOT_RUN: no Metal device (exit 77)\n"); return 77;
        }
        NSError *error=nil; LGCAClosedProfileRuntime *runtime=[[LGCAClosedProfileRuntime alloc] initWithDevice:device];
        id<MTLRenderPipelineState> oldPipeline=MakeBaselinePipeline(device,&error);
        NSString *kernelHash=KernelSHA256(kLGCAClosedProfileMSL);
        if (!runtime||!oldPipeline||[kernelHash isEqual:@"MISSING"]) {
            NSString *message=error.localizedDescription?:@"CA runtime or exact baseline pipeline failed to initialize";
            NSDictionary *fail=@{@"schemaVersion":@1,@"status":@"FAIL",@"device":device.name?:@"unknown",@"initializationError":message,
                @"profileSourceSHA256":SHAString(kLGCAClosedProfileMSL),@"profileKernelSHA256":KernelSHA256(kLGCAClosedProfileMSL),@"baselineSourceSHA256":SHAString(kLGCAClosedBaselineMSL)};
            WriteJSON(CaseFile(outRoot,@"run.json"),fail); fprintf(stderr,"FAIL: %s\n",message.UTF8String); return 1;
        }
        id<MTLCommandQueue> queue=[device newCommandQueue]; id<MTLTexture> glyph=MakeGlyphMask(device);
        if (!queue||!glyph) { fprintf(stderr,"FAIL: command queue or safe zero glyph mask allocation failed\n"); return 1; }
        NSMutableArray *records=[NSMutableArray array]; BOOL allOK=YES;
        NSString *expectOpaque=@"different",*expectFallback=@"equal";
        NSUInteger side=132; std::vector<uint8_t> opaque=MakeGrid(side,side);
        LGCAClosedTestUniforms lightOffU=Uniforms(side,side,side,side,2.0f,0.0f);
        CaseResult lightOff=RunCase(outRoot,records,device,queue,runtime,oldPipeline,glyph,@"opaque-candidate-glare-off",side,side,side,side,opaque,lightOffU,true,expectOpaque);
        LGCAClosedTestUniforms lightOnU=Uniforms(side,side,side,side,2.0f,1.0f);
        CaseResult lightOn=RunCase(outRoot,records,device,queue,runtime,oldPipeline,glyph,@"opaque-candidate-glare-on",side,side,side,side,opaque,lightOnU,true,expectOpaque);
        DiffStats glareDiff=Compare(lightOff.profilePixels,lightOn.profilePixels);
        DiffStats offVsOld=Compare(lightOff.oldPixels,lightOff.profilePixels), onVsOld=Compare(lightOn.oldPixels,lightOn.profilePixels);
        bool glareAlphaSame=glareDiff.alphaDifferentBytes==0, glareLocalDiff=glareDiff.rgbDifferentBytes>0;
        bool candidateGeometryDiff=offVsOld.rgbDifferentBytes>0&&onVsOld.rgbDifferentBytes>0;
        lightOff.record[@"glare0VsGlare1"]=@{@"differentPixelCount":N(glareDiff.differentPixels),@"differentByteCount":N(glareDiff.differentBytes),@"rgbDifferentByteCount":N(glareDiff.rgbDifferentBytes),@"maxByteDiff":@(glareDiff.maxByteDiff),@"alphaDifferentByteCount":N(glareDiff.alphaDifferentBytes)};
        lightOn.record[@"glare0VsGlare1"]=lightOff.record[@"glare0VsGlare1"];
        lightOff.record[@"glareAssertions"]=@{@"alphaIdentical":@(glareAlphaSame),@"localRGBDifference":@(glareLocalDiff),@"opaqueCandidateRGBDiffersFromOld":@(candidateGeometryDiff),@"offRGBBytesVsOld":N(offVsOld.rgbDifferentBytes),@"onRGBBytesVsOld":N(onVsOld.rgbDifferentBytes)};
        lightOn.record[@"glareAssertions"]=lightOff.record[@"glareAssertions"];
        if (!glareAlphaSame||!glareLocalDiff||!candidateGeometryDiff) { lightOff.record[@"status"]=@"FAIL"; lightOn.record[@"status"]=@"FAIL"; }
        allOK=allOK&&glareAlphaSame&&glareLocalDiff&&candidateGeometryDiff;
        // Original project artwork is a fixed test INPUT, never a CA capture.
        if (argc<3) { fprintf(stderr,"FAIL missing deterministic botanical input\n"); return 1; }
        NSData *input=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[2]]];
        if (input.length!=132u*132u*4u) { fprintf(stderr,"FAIL botanical input length\n"); return 1; }
        std::vector<uint8_t> botanical(input.length);memcpy(botanical.data(),input.bytes,input.length);
        for (size_t i=3;i<botanical.size();i+=4) if(botanical[i]!=255) return 1;
        std::vector<uint8_t> idleNatural[2],releaseNatural[2];
        for (unsigned state=0;state<3;state++) for (unsigned light=0;light<2;light++) {
            NSString *stateName=@[@"idle",@"pressure",@"release"][state];
            NSString *name=[NSString stringWithFormat:@"botanical-%@-light%u",stateName,light];
            LGCAClosedTestUniforms u=Uniforms(132,132,132,132,2.0f,(float)light);
            if(state==1) { u.glassThickness=52.8f;u.refractionScale=1.8f; }
            CaseResult r=RunCase(outRoot,records,device,queue,runtime,oldPipeline,glyph,name,132,132,132,132,botanical,u,true,nil);
            r.record[@"sourceKind"]=@"Original fixed botanical test artwork, not CA scene";
            r.record[@"pressureIsSyntheticParameterNotRealTouch"]=@YES;
            if(state==0)idleNatural[light]=r.profilePixels;
            if(state==2)releaseNatural[light]=r.profilePixels;
        }
        bool naturalRelease=Compare(idleNatural[0],releaseNatural[0]).differentBytes==0 && Compare(idleNatural[1],releaseNatural[1]).differentBytes==0;
        allOK=allOK&&naturalRelease;
        // A single damaged texel in a remote corner must reject the whole candidate,
        // even though it is outside the central synthetic shape and ordinary taps.
        for (uint8_t alpha : {uint8_t(0),uint8_t(64),uint8_t(128),uint8_t(254)}) {
            std::vector<uint8_t> damaged=opaque; DamagePixel(damaged,side,side-2,side-2,alpha,alpha+3);
            NSString *name=[NSString stringWithFormat:@"fallback-far-alpha-%u",(unsigned)alpha];
            CaseResult r=RunCase(outRoot,records,device,queue,runtime,oldPipeline,glyph,name,side,side,side,side,damaged,Uniforms(side,side,side,side,2.0f,0.0f),false,expectFallback);
            allOK=allOK&&r.profilePixels.size()==r.oldPixels.size()&&Compare(r.oldPixels,r.profilePixels).differentBytes==0;
        }
        std::vector<uint8_t> mixed=opaque; const uint8_t alphas[9]={0,64,128,255,0,128,64,255,0};
        for (unsigned i=0;i<9;++i) DamagePixel(mixed,side,side-5+(i%3),side-5+(i/3),alphas[i],i*13);
        CaseResult mixedR=RunCase(outRoot,records,device,queue,runtime,oldPipeline,glyph,@"fallback-mixed-alpha-neighborhood",side,side,side,side,mixed,Uniforms(side,side,side,side,2.0f,0.0f),false,expectFallback);
        allOK=allOK&&Compare(mixedR.oldPixels,mixedR.profilePixels).differentBytes==0;
        // buttonCandidate 0 and 1 are deliberately the old branch, not profile opt-ins.
        for (float candidate : {0.0f,1.0f}) {
            NSString *name=[NSString stringWithFormat:@"old-branch-candidate-%.0f",candidate];
            CaseResult r=RunCase(outRoot,records,device,queue,runtime,oldPipeline,glyph,name,side,side,side,side,opaque,Uniforms(side,side,side,side,candidate,0.0f),true,expectFallback);
            allOK=allOK&&Compare(r.oldPixels,r.profilePixels).differentBytes==0;
        }
        // Invalid full-shape conditions must remain the byte-exact baseline branch.
        LGCAClosedTestUniforms glyphBad=Uniforms(side,side,side,side,2.0f,0.0f);
        glyphBad.useGlyphMask=1.0f; glyphBad.shapeScale=0.0f; glyphBad.shapeOrigin=simd_make_float2(0,0); glyphBad.shapeSize=simd_make_float2(0,0);
        CaseResult glyphGate=RunCase(outRoot,records,device,queue,runtime,oldPipeline,glyph,@"old-branch-useGlyphMask-zero-shape",side,side,side,side,opaque,glyphBad,true,expectFallback);
        allOK=allOK&&Compare(glyphGate.oldPixels,glyphGate.profilePixels).differentBytes==0;
        LGCAClosedTestUniforms subshape=Uniforms(side,side,side,side,2.0f,0.0f);
        subshape.shapeScale=0.5f; subshape.shapeOrigin=simd_make_float2(34,34); subshape.shapeSize=simd_make_float2(64,64);
        CaseResult shapeGate=RunCase(outRoot,records,device,queue,runtime,oldPipeline,glyph,@"old-branch-non-fullshape",side,side,side,side,opaque,subshape,true,expectFallback);
        allOK=allOK&&Compare(shapeGate.oldPixels,shapeGate.profilePixels).differentBytes==0;
        // Runtime limits allow these real sRGB sources. The 132->134 case exercises
        // the original +/-2 output builder boundary and verifies transparent skirts.
        for (NSUInteger dim : {NSUInteger(131),NSUInteger(132),NSUInteger(133)}) {
            std::vector<uint8_t> grid=MakeGrid(dim,dim);
            NSString *name=[NSString stringWithFormat:@"opaque-size-%lu",(unsigned long)dim];
            CaseResult r=RunCase(outRoot,records,device,queue,runtime,oldPipeline,glyph,name,dim,dim,dim,dim,grid,Uniforms(dim,dim,dim,dim,2.0f,0.0f),true,nil);
            allOK=allOK&&r.oldPixels.size()==dim*dim*4&&r.profilePixels.size()==dim*dim*4;
        }
        std::vector<uint8_t> edgeSource=MakeGrid(132,132);
        CaseResult edge=RunCase(outRoot,records,device,queue,runtime,oldPipeline,glyph,@"opaque-size-132-output-134",132,132,134,134,edgeSource,Uniforms(132,132,134,134,2.0f,0.0f),true,nil);
        bool edgeTransparent=IsTransparentBorder(edge.oldPixels,134,134)&&IsTransparentBorder(edge.profilePixels,134,134);
        bool edgeSame=BorderEqual(edge.oldPixels,edge.profilePixels,134,134);
        NSMutableDictionary *edgeAssertions=[edge.record[@"assertions"] mutableCopy];
        edgeAssertions[@"outerOutputBorderTransparent"]=@(edgeTransparent); edgeAssertions[@"outerOutputBorderMatchesOld"]=@(edgeSame);
        edge.record[@"assertions"]=edgeAssertions;
        if (!edgeTransparent||!edgeSame) edge.record[@"status"]=@"FAIL";
        allOK=allOK&&edgeTransparent&&edgeSame;
        bool auditFailureOK=TestAuditFailClosed(outRoot,device,queue,runtime,oldPipeline,glyph);
        bool resourceRejectionOK=TestResourceRejections(outRoot,device,queue,runtime);
        bool formatOK=TestFormat80(outRoot,device,queue,runtime);
        bool poolOK=TestPool(outRoot,device,queue,runtime);
        bool caseFilesOK=WriteCaseReports(outRoot,records);
        bool casesPass=AllCaseRecordsPass(records);
        allOK=allOK&&auditFailureOK&&resourceRejectionOK&&formatOK&&poolOK&&caseFilesOK&&casesPass;
        NSMutableArray *caseNames=[NSMutableArray array]; for (NSDictionary *r in records) [caseNames addObject:r[@"case"]];
        NSDictionary *run=@{
            @"schemaVersion":@1,@"status":allOK?@"PASS":@"FAIL",@"device":device.name?:@"unknown",
            @"deviceRegistryID":@((uint64_t)device.registryID),@"pixelFormat":@{@"sRGB":@(MTLPixelFormatBGRA8Unorm_sRGB),@"rejectedNonSRGB":@(MTLPixelFormatBGRA8Unorm)},
            @"compiledProfileMacro":@1,@"uniformBytes":@(sizeof(LGCAClosedTestUniforms)),
            @"baselineShaderSHA256":SHAString(kLGCAClosedBaselineMSL),@"profileShaderSHA256":SHAString(kLGCAClosedProfileMSL),
            @"profileShaderDeclaredSHA256":[NSString stringWithUTF8String:kLGCAClosedProfileMSLSHA256],@"profileKernelSHA256":KernelSHA256(kLGCAClosedProfileMSL),
            @"realGPU":@YES,@"usesWindowScreenCaptureOrCAContext":@NO,@"cpuMaterialRendering":@NO,
            @"syntheticInput":@"CPU-generated deterministic BGRA8Unorm_sRGB grey grid only; same input bytes are sent to the old and profile pipelines.",
            @"comparison":@"Packed readback BGRA bytes from completed real Metal command buffers; CPU only compares bytes and writes raw/PNG artifacts.",
            @"scopeLimit":@"This is a synthetic-source Metal regression, not a measurement of an ordinary live CA optical source or whole-screen visual quality.",
            @"poolTestScope":@"Three uncommitted command-buffer leases validate the fixed three-slot bound only; they are not GPU-concurrency/performance results.",
            @"glareComparison":@{@"profileOutputDifferentPixels":N(glareDiff.differentPixels),@"profileOutputDifferentBytes":N(glareDiff.differentBytes),@"profileOutputDifferentRGBBytes":N(glareDiff.rgbDifferentBytes),@"maxByteDiff":@(glareDiff.maxByteDiff),@"alphaDifferentByteCount":N(glareDiff.alphaDifferentBytes),@"alphaIdentical":@(glareAlphaSame),@"localRGBDifferencePresent":@(glareLocalDiff),@"opaqueCandidateRGBDiffersFromOld":@(candidateGeometryDiff)},
            @"auditFailureInjectionTest":@(auditFailureOK),@"resourceRejectionTest":@(resourceRejectionOK),@"naturalReleaseMatchesIdle":@(naturalRelease),
            @"format80Test":@(formatOK),@"poolTest":@(poolOK),@"caseArtifactsWritten":@(caseFilesOK),@"caseCount":@(records.count),@"cases":caseNames,
            @"rawLayout":@"rawBGRA files are tightly packed 4-byte BGRA rows, top-to-bottom, no header; these are authoritative.",
            @"pngNote":@"PNG files are ImageIO previews wrapped from captured GPU output bytes; rawBGRA is authoritative for exact comparisons.",
            @"exitCode":@(allOK?0:1)
        };
        WriteJSON(CaseFile(outRoot,@"run.json"),run);
        fprintf(allOK?stdout:stderr,"%s: %lu render cases, format80=%s, pool=%s, output=%s\n",allOK?"PASS":"FAIL",(unsigned long)records.count,formatOK?"PASS":"FAIL",poolOK?"PASS":"FAIL",outRoot.fileSystemRepresentation);
        return allOK?0:1;
    }
}
