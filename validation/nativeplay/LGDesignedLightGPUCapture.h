/* Test-only single-TU implementation header. Import only from LGLocalButtonMaterialView.mm.
 * No source/frame lease is retained here; compile out unless the experiment macro is exactly 1. */
#if defined(LG_LOCAL_DESIGNED_LIGHT_EXPERIMENT) && LG_LOCAL_DESIGNED_LIGHT_EXPERIMENT == 1
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#import "LGLocalButtonUniforms.h"
#include <math.h>
#include <string.h>

NS_ASSUME_NONNULL_BEGIN
@class LGDesignedLightCaptureRecord;
@interface LGDesignedLightCapture : NSObject
@property(nonatomic,copy,readonly) NSString *runIdentifier;
@property(nonatomic,copy,readonly) NSString *directoryName;
- (nullable instancetype)init;
- (nullable LGDesignedLightCaptureRecord *)encodeForCommand:(id<MTLCommandBuffer>)command
    device:(id<MTLDevice>)device pipeline:(id<MTLRenderPipelineState>)pipeline
    sampler:(id<MTLSamplerState>)sampler drawable:(id<MTLTexture>)drawable
    source:(id<MTLTexture>)source uniforms:(LGLocalButtonUniforms)uniforms
    state:(LGButtonOpticalState)state contract:(LGLocalButtonSourceContract)contract
    serial:(uint64_t)serial;
@end
@interface LGDesignedLightCaptureRecord : NSObject
@property(nonatomic,copy,readonly) NSString *stateName;
/* Call exactly once from this command buffer's completion handler. */
- (void)completeWithCommandSucceeded:(BOOL)succeeded;
@end
NS_ASSUME_NONNULL_END

static NSString *LGDLHexSHA256(const void *bytes,size_t length) {
    unsigned char d[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(bytes,(CC_LONG)length,d);
    static const char h[]="0123456789abcdef"; char out[65];
    for (unsigned i=0;i<sizeof(d);i++) { out[2*i]=h[d[i]>>4]; out[2*i+1]=h[d[i]&15]; }
    out[64]=0; return [NSString stringWithUTF8String:out];
}
static id LGDLNumber(double x) { return isfinite(x)?@(x):NSNull.null; }
static NSArray *LGDLRect(CGRect r) {
    return @[LGDLNumber(r.origin.x),LGDLNumber(r.origin.y),
             LGDLNumber(r.size.width),LGDLNumber(r.size.height)];
}
static NSString *LGDLPhase(LGButtonOpticalState s) {
    switch (s.phase) {
        case LGOpticalIdle:return @"idle"; case LGOpticalTrackingInside:return @"trackingInside";
        case LGOpticalTrackingOutside:return @"trackingOutside"; case LGOpticalReleasing:return @"releasing";
        case LGOpticalCancelled:return @"cancelled"; case LGOpticalSuspended:return @"suspended";
    } return @"unknown";
}
static NSDictionary *LGDLBaseMetadata(NSString *run,NSString *dir,NSString *name,uint64_t serial,
    LGButtonOpticalState s,LGLocalButtonSourceContract c,id<MTLTexture> _Nullable source,
    LGLocalButtonUniforms u) {
    return @{@"schemaVersion":@1,@"runIdentifier":run,@"directoryName":dir,@"state":name,
      @"actualSubmissionSerial":@(serial),@"result":@"ENCODING_PENDING",@"capturePass":@NO,
      @"commandSucceeded":@NO,@"statePhase":LGDLPhase(s),@"pressure":LGDLNumber(s.pressure),
      @"target":LGDLNumber(s.target),@"tracking":@(s.tracking),@"touchValid":@(s.touchValid),
      @"contactNormalized":(s.touchValid&&isfinite(s.touchX)&&isfinite(s.touchY))?@[@(s.touchX),@(s.touchY)]:NSNull.null,
      @"stateGeometryGeneration":@(s.geometryGeneration),
      @"sourceOwnerToken":@(c.ownerInstanceToken),@"sourceOwnerGeneration":@(c.ownerGeneration),
      @"sourceFrameGeneration":@(c.frameGeneration),@"sourceGeometryGeneration":@(c.targetGeometryGeneration),
      @"sourceFrameTimestampMonotonic":LGDLNumber(c.frameTimestampMonotonic),
      @"sourceRectOwnerPoints":LGDLRect(c.sourceRectInOwnerPoints),
      @"targetRectOwnerPoints":LGDLRect(c.targetRectInOwnerPoints),
      @"sourceTextureWidth":@(source?source.width:c.textureWidth),
      @"sourceTextureHeight":@(source?source.height:c.textureHeight),
      @"sourcePixelFormat":@(source?source.pixelFormat:c.pixelFormat),
      @"sourceImmutableUntilFrameReleased":@(c.immutableUntilFrameReleased),
      @"originalUniformsByteLength":@(sizeof(LGLocalButtonUniforms)),
      @"originalUniformsSHA256":LGDLHexSHA256(&u,sizeof(u)),
      @"originalUniformsBase64":[[NSData dataWithBytes:&u length:sizeof(u)] base64EncodedStringWithOptions:0],
      @"originalUniformFresnelGlareStrength":@(u.fresnelGlareStrength),
      @"capturePixelFormat":@"BGRA8Unorm_sRGB",@"captureWidth":@132,@"captureHeight":@132,
      @"drawableReadback":@NO,@"screenScreenshot":@NO,@"sourceFrameRetainedByCaptureHelper":@NO};
}
static NSData * _Nullable LGDLJSON(NSDictionary *m) {
    return [NSJSONSerialization dataWithJSONObject:m options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
}
static BOOL LGDLWriteJSON(NSURL *url,NSDictionary *m,NSError **error) {
    NSData *d=LGDLJSON(m); return d && [d writeToURL:url options:NSDataWritingAtomic error:error];
}
static id<MTLTexture> _Nullable LGDLNewSharedTexture(id<MTLDevice> device,NSString *label) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
        width:132 height:132 mipmapped:NO];
    d.storageMode=MTLStorageModeShared; d.cpuCacheMode=MTLCPUCacheModeDefaultCache;
    d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
    id<MTLTexture> t=[device newTextureWithDescriptor:d]; t.label=label; return t;
}
static BOOL LGDLEncodePass(id<MTLCommandBuffer> cb,id<MTLRenderPipelineState> p,
    id<MTLSamplerState> sm,id<MTLTexture> src,id<MTLTexture> dst,LGLocalButtonUniforms u) {
    MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture=dst; rp.colorAttachments[0].loadAction=MTLLoadActionClear;
    rp.colorAttachments[0].storeAction=MTLStoreActionStore; rp.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
    id<MTLRenderCommandEncoder> e=[cb renderCommandEncoderWithDescriptor:rp]; if (!e) return NO;
    [e setRenderPipelineState:p]; [e setFragmentTexture:src atIndex:0];
    [e setFragmentTexture:src atIndex:1]; [e setFragmentSamplerState:sm atIndex:0];
    [e setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding]; return YES;
}
static NSData * _Nullable LGDLReadSharedBGRA(id<MTLTexture> t) {
    if (!t || t.storageMode!=MTLStorageModeShared || t.pixelFormat!=MTLPixelFormatBGRA8Unorm_sRGB ||
        t.width!=132 || t.height!=132) return nil;
    const NSUInteger tight=132u*4u, aligned=768u; /* 256-byte Metal row-pitch alignment */
    NSMutableData *padded=[NSMutableData dataWithLength:aligned*132u];
    [t getBytes:padded.mutableBytes bytesPerRow:aligned fromRegion:MTLRegionMake2D(0,0,132,132) mipmapLevel:0];
    NSMutableData *raw=[NSMutableData dataWithLength:tight*132u];
    for (NSUInteger y=0;y<132;y++) memcpy((uint8_t *)raw.mutableBytes+y*tight,(const uint8_t *)padded.bytes+y*aligned,tight);
    return raw;
}
static BOOL LGDLWritePNG(NSURL *url,NSData *bgra) {
    CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)bgra);
    CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGBitmapInfo bi=(CGBitmapInfo)(kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst);
    CGImageRef image=provider&&cs?CGImageCreate(132,132,8,32,132u*4u,cs,bi,provider,NULL,false,kCGRenderingIntentDefault):NULL;
    NSMutableData *png=[NSMutableData data];
    CGImageDestinationRef dst=image?CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png,CFSTR("public.png"),1,NULL):NULL;
    BOOL ok=NO; if (dst) { CGImageDestinationAddImage(dst,image,NULL); ok=CGImageDestinationFinalize(dst); }
    if (dst) CFRelease(dst); if (image) CGImageRelease(image); if (cs) CGColorSpaceRelease(cs); if (provider) CGDataProviderRelease(provider);
    return ok && [png writeToURL:url options:NSDataWritingAtomic error:nil];
}

@interface LGDesignedLightCaptureRecord ()
@property(nonatomic,copy,readwrite) NSString *stateName;
@property(nonatomic,strong) NSURL *directoryURL;
@property(nonatomic,copy) NSDictionary *metadata;
@property(nonatomic,strong) id<MTLTexture> offTexture;
@property(nonatomic,strong) id<MTLTexture> onTexture;
@end
@implementation LGDesignedLightCaptureRecord
- (void)completeWithCommandSucceeded:(BOOL)succeeded {
    @synchronized(self) {
        if (!self.offTexture || !self.onTexture) return;
        NSString *stem=self.stateName;
        NSURL *offRaw=[self.directoryURL URLByAppendingPathComponent:[stem stringByAppendingString:@"-off.bgra"]];
        NSURL *onRaw=[self.directoryURL URLByAppendingPathComponent:[stem stringByAppendingString:@"-on.bgra"]];
        NSURL *offPNG=[self.directoryURL URLByAppendingPathComponent:[stem stringByAppendingString:@"-off.png"]];
        NSURL *onPNG=[self.directoryURL URLByAppendingPathComponent:[stem stringByAppendingString:@"-on.png"]];
        NSURL *json=[self.directoryURL URLByAppendingPathComponent:[stem stringByAppendingString:@".json"]];
        NSMutableDictionary *m=[self.metadata mutableCopy];
        m[@"commandSucceeded"]=@(succeeded); m[@"capturePass"]=@NO;
        if (!succeeded) { m[@"result"]=@"COMMAND_FAILED"; m[@"failure"]=@"Original command buffer did not complete successfully; no texture readback performed.";
            NSError *e=nil; if (!LGDLWriteJSON(json,m,&e)) NSLog(@"LGDesignedLightCapture manifest write failed: %@",e.localizedDescription);
            self.offTexture=nil; self.onTexture=nil; return; }
        m[@"result"]=@"GPU_COMPLETED_READBACK_PENDING";
        NSError *e=nil; if (!LGDLWriteJSON(json,m,&e)) NSLog(@"LGDesignedLightCapture pending manifest write failed: %@",e.localizedDescription);
        NSData *off=LGDLReadSharedBGRA(self.offTexture), *on=LGDLReadSharedBGRA(self.onTexture);
        BOOL ok=off&&on;
        if (ok) ok=[off writeToURL:offRaw options:NSDataWritingAtomic error:&e] &&
                  [on writeToURL:onRaw options:NSDataWritingAtomic error:&e] && LGDLWritePNG(offPNG,off) && LGDLWritePNG(onPNG,on);
        if (!ok) {
            [[NSFileManager defaultManager] removeItemAtURL:offRaw error:nil]; [[NSFileManager defaultManager] removeItemAtURL:onRaw error:nil];
            [[NSFileManager defaultManager] removeItemAtURL:offPNG error:nil]; [[NSFileManager defaultManager] removeItemAtURL:onPNG error:nil];
            m[@"result"]=@"READBACK_OR_FILE_WRITE_FAILED"; m[@"failure"]=e.localizedDescription?:@"Shared texture readback or PNG/raw write failed.";
        } else {
            m[@"result"]=@"GPU_COMPLETED_READBACK_SAVED"; m[@"capturePass"]=@YES;
            m[@"rawBytesPerRow"]=@528; m[@"getBytesBytesPerRow"]=@768; m[@"rawPixelOrder"]=@"BGRA8"; m[@"pngColorSpace"]=@"sRGB";
            m[@"files"]=@{@"offRaw":offRaw.lastPathComponent,@"offPNG":offPNG.lastPathComponent,
                           @"onRaw":onRaw.lastPathComponent,@"onPNG":onPNG.lastPathComponent};
        }
        if (!LGDLWriteJSON(json,m,&e)) NSLog(@"LGDesignedLightCapture final manifest write failed: %@",e.localizedDescription);
        self.offTexture=nil; self.onTexture=nil;
    }
}
@end

@interface LGDesignedLightCapture ()
@property(nonatomic,copy,readwrite) NSString *runIdentifier;
@property(nonatomic,copy,readwrite) NSString *directoryName;
@property(nonatomic,strong) NSURL *directoryURL;
@property(nonatomic,strong) NSMutableSet<NSString *> *claimedStates;
@property(nonatomic,assign) BOOL hadContact;
@end
@implementation LGDesignedLightCapture
- (instancetype)init {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"org.liquidass.native-play-lab"]) return nil;
    if (!(self=[super init])) return nil;
    _runIdentifier=NSUUID.UUID.UUIDString;
    _directoryName=[@"LGDesignedLightGPUCapture_" stringByAppendingString:_runIdentifier];
    NSURL *docs=[[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    _directoryURL=[docs URLByAppendingPathComponent:_directoryName isDirectory:YES];
    NSError *e=nil; if (!docs || ![[NSFileManager defaultManager] createDirectoryAtURL:_directoryURL withIntermediateDirectories:NO attributes:nil error:&e]) return nil;
    _claimedStates=[NSMutableSet set]; return self;
}
- (NSString *)candidateAndClaim:(LGButtonOpticalState)s {
    if (!s.eligible) return nil;
    @synchronized(self) {
        BOOL contact=s.tracking && s.touchValid && isfinite(s.pressure) && s.pressure>0.0f &&
            (s.phase==LGOpticalTrackingInside||s.phase==LGOpticalTrackingOutside) &&
            isfinite(s.touchX)&&isfinite(s.touchY)&&s.touchX>=0&&s.touchX<=1&&s.touchY>=0&&s.touchY<=1;
        if (contact) self.hadContact=YES;
        NSString *n=nil;
        if (!self.hadContact && !s.tracking && !s.touchValid && s.phase==LGOpticalIdle && s.pressure==0.0f && s.target==0.0f) n=@"idle";
        else if (s.tracking && s.touchValid && isfinite(s.pressure) && s.pressure>=0.9995f &&
                 isfinite(s.touchX)&&s.touchX>=0.0f&&s.touchX<=0.1f&&isfinite(s.touchY)&&s.touchY>=0.0f&&s.touchY<=1.0f &&
                 (s.phase==LGOpticalTrackingInside)) n=@"left";
        else if (s.tracking && s.touchValid && isfinite(s.pressure) && s.pressure>=0.9995f &&
                 isfinite(s.touchX)&&s.touchX>=0.9f&&s.touchX<=1.0f&&isfinite(s.touchY)&&s.touchY>=0.0f&&s.touchY<=1.0f &&
                 (s.phase==LGOpticalTrackingInside)) n=@"right";
        else if (self.hadContact && !s.tracking && s.pressure==0.0f && s.target==0.0f &&
                 (s.phase==LGOpticalIdle||s.phase==LGOpticalReleasing)) n=@"release";
        if (!n || [self.claimedStates containsObject:n] || self.claimedStates.count>=4) return nil;
        [self.claimedStates addObject:n]; return n;
    }
}
- (void)writeEncodingFailure:(NSString *)name serial:(uint64_t)serial state:(LGButtonOpticalState)s
    contract:(LGLocalButtonSourceContract)c source:(id<MTLTexture>)source uniforms:(LGLocalButtonUniforms)u reason:(NSString *)reason {
    NSMutableDictionary *m=[LGDLBaseMetadata(self.runIdentifier,self.directoryName,name,serial,s,c,source,u) mutableCopy];
    m[@"result"]=@"ENCODING_FAILED"; m[@"failure"]=reason; m[@"capturePass"]=@NO;
    NSURL *url=[self.directoryURL URLByAppendingPathComponent:[name stringByAppendingString:@".json"]];
    NSError *e=nil; if (!LGDLWriteJSON(url,m,&e)) NSLog(@"LGDesignedLightCapture failure manifest write failed: %@",e.localizedDescription);
}
- (LGDesignedLightCaptureRecord *)encodeForCommand:(id<MTLCommandBuffer>)command device:(id<MTLDevice>)device
    pipeline:(id<MTLRenderPipelineState>)pipeline sampler:(id<MTLSamplerState>)sampler drawable:(id<MTLTexture>)drawable
    source:(id<MTLTexture>)source uniforms:(LGLocalButtonUniforms)uniforms state:(LGButtonOpticalState)state
    contract:(LGLocalButtonSourceContract)contract serial:(uint64_t)serial {
    NSString *name=[self candidateAndClaim:state]; if (!name) return nil;
    NSString *why=nil; const float w=uniforms.outputResolution.x,h=uniforms.outputResolution.y;
    BOOL valid=command&&device&&pipeline&&sampler&&drawable&&source&&
        command.status==MTLCommandBufferStatusNotEnqueued && command.commandQueue.device==device &&
        pipeline.device==device && sampler.device==device && source.device==device && drawable.device==device &&
        source.textureType==MTLTextureType2D && source.sampleCount==1 && (source.usage&MTLTextureUsageShaderRead) &&
        source.width==contract.textureWidth && source.height==contract.textureHeight && contract.immutableUntilFrameReleased &&
        drawable.pixelFormat==MTLPixelFormatBGRA8Unorm_sRGB && drawable.width==132 && drawable.height==132 &&
        isfinite(w)&&isfinite(h)&&w==132.0f&&h==132.0f && sizeof(LGLocalButtonUniforms)==240;
    if (!valid) why=@"Invalid command/device/source contract, non-132 drawable, or uniform ABI; no capture encoders appended.";
    id<MTLTexture> off=nil; id<MTLTexture> on=nil;
    if (valid) { off=LGDLNewSharedTexture(device,@"LGDesignedLight OFF readback"); on=LGDLNewSharedTexture(device,@"LGDesignedLight ON readback");
        if (!off||!on) { valid=NO; why=@"Could not allocate two 132x132 BGRA8Unorm_sRGB Shared textures."; } }
    LGLocalButtonUniforms uoff=uniforms,uon=uniforms; uoff.fresnelGlareStrength=0.0f; uon.fresnelGlareStrength=1.0f;
    const size_t gate=offsetof(LGLocalButtonUniforms,fresnelGlareStrength), tail=gate+sizeof(float);
    if (valid && (memcmp(&uoff,&uon,gate)!=0 || memcmp((const char *)&uoff+tail,(const char *)&uon+tail,sizeof(uoff)-tail)!=0)) {
        valid=NO; why=@"Uniform variants differ outside fresnelGlareStrength."; }
    BOOL encodedOff=NO,encodedOn=NO;
    if (valid) { encodedOff=LGDLEncodePass(command,pipeline,sampler,source,off,uoff);
        if (encodedOff) encodedOn=LGDLEncodePass(command,pipeline,sampler,source,on,uon);
        if (!encodedOff||!encodedOn) { valid=NO; why=@"One or both auxiliary render encoders could not be created."; } }
    if (!valid) { [self writeEncodingFailure:name serial:serial state:state contract:contract source:source uniforms:uniforms reason:why?:@"Unknown encode failure."]; return nil; }
    NSMutableDictionary *m=[LGDLBaseMetadata(self.runIdentifier,self.directoryName,name,serial,state,contract,source,uniforms) mutableCopy];
    m[@"result"]=@"ENCODED_AWAITING_ORIGINAL_COMMAND_COMPLETION";
    m[@"variantOnlyUniformField"]=@"fresnelGlareStrength"; m[@"offGate"]=@0; m[@"onGate"]=@1;
    m[@"variantBytesDifferOnlyAtGate"]=@YES;
    m[@"sameImmutableSourceTextureArgumentForBothVariants"]=@YES;
    m[@"samePipelineObjectAndSamplerObjectAsCallerArguments"]=@YES;
    m[@"sameCommandBufferAsPrimaryDrawableSubmission"]=@YES;
    m[@"auxiliaryTargetsAreDistinctFromDrawable"]=@YES;
    m[@"auxiliaryPassesArePresented"]=@NO; m[@"auxiliaryAreScreenshots"]=@NO;
    m[@"actualDrawableReadbackPerformed"]=@NO; m[@"primaryFramebufferOnlyChanged"]=@NO;
    m[@"outputs"]=@{@"off":@"OFF",@"on":@"ON"};
    LGDesignedLightCaptureRecord *r=[LGDesignedLightCaptureRecord new]; r.stateName=name; r.directoryURL=self.directoryURL;
    r.metadata=m; r.offTexture=off; r.onTexture=on; return r;
}
@end
#endif /* LG_LOCAL_DESIGNED_LIGHT_EXPERIMENT == 1 */
