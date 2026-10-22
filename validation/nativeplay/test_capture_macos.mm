// Mac-only Objective-C++ regression harness; one translation unit owns helper implementation.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CommonCrypto/CommonDigest.h>
#import "LGDesignedLightGPUCapture.h"
#import "LGLocalButtonShaderSource.h"
#include <cmath>
#include <cstdio>
#include <cstring>

static BOOL Check(BOOL ok, NSString *message) {
    if (!ok) fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    return ok;
}
static NSURL *DocumentsURL(void) {
    return [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
        inDomains:NSUserDomainMask] firstObject];
}
static NSString *SHA256(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    static const char hex[]="0123456789abcdef"; char out[65];
    for (NSUInteger i=0;i<sizeof(digest);i++) {
        out[i*2]=hex[digest[i]>>4]; out[i*2+1]=hex[digest[i]&15];
    }
    out[64]=0; return [NSString stringWithUTF8String:out];
}
static LGButtonOpticalState StateFor(NSString *name) {
    LGButtonOpticalState s={0}; s.eligible=true; s.geometryGeneration=73;
    if ([name isEqual:@"left"] || [name isEqual:@"right"]) {
        s.phase=LGOpticalTrackingInside; s.tracking=true; s.touchValid=true;
        s.pressure=1.0f; s.target=1.0f;
        s.touchX=[name isEqual:@"left"]?0.05f:0.95f;
        s.touchY=[name isEqual:@"left"]?0.25f:0.5f;
    } else { s.phase=LGOpticalIdle; s.pressure=0; s.target=0; }
    return s;
}
static LGLocalButtonSourceContract Contract(uint64_t serial) {
    LGLocalButtonSourceContract c={0};
    c.sourceRectInOwnerPoints=CGRectMake(0,0,44,44);
    c.targetRectInOwnerPoints=CGRectMake(0,0,44,44);
    c.textureWidth=132; c.textureHeight=132; c.pixelFormat=MTLPixelFormatBGRA8Unorm_sRGB;
    c.pointScale=3.0f; c.ownerInstanceToken=0x4c47444c; c.ownerGeneration=1;
    c.frameGeneration=serial; c.targetGeometryGeneration=73;
    c.frameTimestampMonotonic=NSProcessInfo.processInfo.systemUptime;
    c.sourceKind=LGLocalSourceStaticAsset; c.alphaMode=LGLocalAlphaOpaque;
    c.maskKind=LGLocalMaskRounded44; c.backgroundOnly=true;
    c.targetForegroundExcluded=true; c.immutableUntilFrameReleased=true;
    c.sampledRGBIsLinear=true; c.sampledRGBIsPremultiplied=true;
    c.sourceOverscanEnabled=false; return c;
}
static BOOL MakeUniforms(LGButtonOpticalState s, LGLocalButtonSourceContract c,
                         LGLocalButtonUniforms *out) {
    if (!LGLocalButtonBuildUniforms(&c,&s,132,132,3.0f,true,out)) return NO;
    // The primary drawable's exact incoming value is the safety gate under test.
    out->fresnelGlareStrength=1.0f; return YES;
}
static BOOL TestPrimaryStrengthGate(void) {
    struct GateCase { const char *name; float value; BOOL isFinite; } cases[] = {
        {"zero",0.0f,YES}, {"negative",-0.25f,YES},
        {"nan",NAN,NO}, {"positive-infinity",INFINITY,NO},
        {"negative-infinity",-INFINITY,NO}
    };
    for (const auto &g : cases) {
        LGDesignedLightCapture *h=[[LGDesignedLightCapture alloc] init];
        if (!Check(h!=nil,@"matching bundle helper init")) return NO;
        LGLocalButtonUniforms u={0}; u.outputResolution=simd_make_float2(132,132);
        u.fresnelGlareStrength=g.value;
        LGButtonOpticalState s=StateFor(@"idle"); LGLocalButtonSourceContract c={0};
        // Nil GPU arguments prove the helper rejects primary strength first.
        LGDesignedLightCaptureRecord *r=[h encodeForCommand:nil device:nil pipeline:nil
            sampler:nil drawable:nil source:nil uniforms:u state:s contract:c serial:1];
        NSDictionary *suite=[h captureSuiteSnapshot];
        NSDictionary *m=suite[@"stateResults"][@"idle"];
        if (!Check(r==nil,@"bad primary gate returns nil")) return NO;
        if (!Check([suite[@"pass"] boolValue]==NO &&
                   [suite[@"captureSuiteStatus"] isEqual:@"FAIL_CAPTURE_SUITE"],
                   @"bad primary gate fails suite")) return NO;
        if (!Check([m[@"result"] isEqual:@"ENCODING_FAILED"] &&
                   [m[@"capturePass"] boolValue]==NO,
                   @"bad primary gate records encoding failure")) return NO;
        id strength=m[@"primaryDrawableUniformStrength"];
        if (g.isFinite) {
            if (!Check([strength isKindOfClass:NSNumber.class] &&
                       [strength floatValue]==g.value,@"finite original primary strength preserved")) return NO;
        } else if (!Check(strength==NSNull.null,@"NaN/Inf serialized as JSON null")) return NO;
        if (!Check([h.ledger.states[@"idle"][@"result"] isEqual:@"ENCODING_FAILED"],
                   @"public ledger contains failure record")) return NO;
        NSURL *url=[[DocumentsURL() URLByAppendingPathComponent:h.directoryName]
                    URLByAppendingPathComponent:@"idle.json"];
        NSData *json=[NSData dataWithContentsOfURL:url]; NSError *e=nil;
        NSDictionary *disk=json?[NSJSONSerialization JSONObjectWithData:json options:0 error:&e]:nil;
        if (!Check(disk!=nil && [disk[@"primaryDrawableUniformStrength"] isEqual:strength],
                   @"failure metadata persisted with safe original float")) return NO;
        fprintf(stdout,"PASS primary gate %s\n",g.name);
    }
    return YES;
}

static id<MTLTexture> MakeSource(id<MTLDevice> device) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
        MTLPixelFormatBGRA8Unorm_sRGB width:132 height:132 mipmapped:NO];
    d.storageMode=MTLStorageModeShared; d.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> t=[device newTextureWithDescriptor:d]; if (!t) return nil;
    t.label=@"fixed synthetic black-gray static-asset fixture";
    NSMutableData *pixels=[NSMutableData dataWithLength:132u*132u*4u];
    uint8_t *p=(uint8_t *)pixels.mutableBytes;
    for (NSUInteger y=0;y<132;y++) for (NSUInteger x=0;x<132;x++) {
        uint8_t v=(((x/11u)+(y/11u))&1u)?112:12;
        size_t i=(y*132u+x)*4u; p[i]=v; p[i+1]=v; p[i+2]=v; p[i+3]=255;
    }
    [t replaceRegion:MTLRegionMake2D(0,0,132,132) mipmapLevel:0
        withBytes:pixels.bytes bytesPerRow:132u*4u];
    return t;
}
static id<MTLTexture> MakePrimaryTarget(id<MTLDevice> device) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
        MTLPixelFormatBGRA8Unorm_sRGB width:132 height:132 mipmapped:NO];
    d.storageMode=MTLStorageModeShared;
    d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
    id<MTLTexture> t=[device newTextureWithDescriptor:d]; t.label=@"mock real primary drawable target";
    return t;
}
static BOOL MakePipeline(id<MTLDevice> device, id<MTLRenderPipelineState> *pipeline,
                         id<MTLSamplerState> *sampler) {
    NSString *source=[NSString stringWithUTF8String:kLGLocalButtonCandidateMSL];
    NSError *error=nil; id<MTLLibrary> lib=[device newLibraryWithSource:source options:nil error:&error];
    if (!Check(lib!=nil,[NSString stringWithFormat:@"shared shader compiles: %@",error.localizedDescription?:@"no library"])) return NO;
    MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];
    d.label=@"shared LGLocalButton shader source pipeline";
    d.vertexFunction=[lib newFunctionWithName:@"liquidGlassVertex"];
    d.fragmentFunction=[lib newFunctionWithName:@"liquidGlassFragment"];
    d.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm_sRGB;
    MTLRenderPipelineColorAttachmentDescriptor *a=d.colorAttachments[0];
    a.blendingEnabled=YES; a.rgbBlendOperation=MTLBlendOperationAdd;
    a.alphaBlendOperation=MTLBlendOperationAdd;
    a.sourceRGBBlendFactor=MTLBlendFactorOne;
    a.destinationRGBBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
    a.sourceAlphaBlendFactor=MTLBlendFactorOne;
    a.destinationAlphaBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
    *pipeline=[device newRenderPipelineStateWithDescriptor:d error:&error];
    if (!Check(*pipeline!=nil,[NSString stringWithFormat:@"shared pipeline builds: %@",error.localizedDescription?:@"no pipeline"])) return NO;
    MTLSamplerDescriptor *sd=[MTLSamplerDescriptor new];
    sd.minFilter=MTLSamplerMinMagFilterLinear; sd.magFilter=MTLSamplerMinMagFilterLinear;
    sd.sAddressMode=MTLSamplerAddressModeClampToEdge; sd.tAddressMode=MTLSamplerAddressModeClampToEdge;
    *sampler=[device newSamplerStateWithDescriptor:sd];
    return Check(*sampler!=nil,@"linear clamp sampler builds");
}
static LGDesignedLightCaptureRecord *EncodeAndWait(
    LGDesignedLightCapture *helper, id<MTLDevice> device, id<MTLCommandQueue> queue,
    id<MTLRenderPipelineState> pipeline, id<MTLSamplerState> sampler,
    id<MTLTexture> drawable, id<MTLTexture> source, NSString *stateName,
    uint64_t serial, BOOL completionSignal) {
    LGButtonOpticalState state=StateFor(stateName);
    LGLocalButtonSourceContract contract=Contract(serial);
    LGLocalButtonUniforms uniforms={0};
    if (!Check(MakeUniforms(state,contract,&uniforms),@"44pt/3x opt-in shared Uniforms contract builds")) return nil;
    if (!Check(uniforms.outputResolution.x==132.0f && uniforms.outputResolution.y==132.0f &&
               uniforms.shapeScale==1.0f && uniforms.buttonCandidatePointScale==3.0f &&
               contract.targetRectInOwnerPoints.size.width==44.0 &&
               contract.targetRectInOwnerPoints.size.height==44.0 &&
               (![stateName isEqual:@"left"] && ![stateName isEqual:@"right"] ||
                (uniforms.buttonContactEnabled==1.0f &&
                 uniforms.buttonContactCenter.x==state.touchX && uniforms.buttonContactCenter.y==state.touchY)),
               @"44pt shape, 3x output, explicit contact opt-in/coordinates")) return nil;
    if (!Check(contract.sourceKind==LGLocalSourceStaticAsset && contract.immutableUntilFrameReleased &&
               contract.targetGeometryGeneration==state.geometryGeneration &&
               LGLocalValidateSourceContract(&contract,NSProcessInfo.processInfo.systemUptime,
                   contract.ownerInstanceToken,contract.ownerGeneration,contract.frameGeneration,
                   state.geometryGeneration,(uint32_t)source.width,(uint32_t)source.height,
                   (uint32_t)source.pixelFormat,(uint32_t)drawable.pixelFormat,YES,YES)==LGLocalSourceValid,
               @"valid static-source contract, owner/frame/target generations")) return nil;
    id<MTLCommandBuffer> cb=[queue commandBuffer];
    LGDesignedLightCaptureRecord *record=[helper encodeForCommand:cb device:device pipeline:pipeline
        sampler:sampler drawable:drawable source:source uniforms:uniforms state:state
        contract:contract serial:serial];
    if (!Check(record!=nil,@"actual helper appends both GPU passes")) return nil;
    [cb commit]; [cb waitUntilCompleted];
    if (!Check(cb.status==MTLCommandBufferStatusCompleted && cb.error==nil,
               @"real Metal command buffer completed without error")) return nil;
    [record completeWithCommandSucceeded:completionSignal];
    return record;
}
static BOOL VerifySavedState(LGDesignedLightCapture *helper, NSString *stateName) {
    NSDictionary *suite=[helper captureSuiteSnapshot];
    NSDictionary *m=suite[@"stateResults"][stateName];
    if (!Check(m!=nil && [m[@"result"] isEqual:@"GPU_COMPLETED_READBACK_SAVED"] &&
               [m[@"capturePass"] boolValue] && [m[@"commandSucceeded"] boolValue] &&
               [m[@"bundleIdentifier"] isEqual:@"org.liquidass.native-play-lab"],
               [NSString stringWithFormat:@"%@ saved actual GPU readback",stateName])) return NO;
    if (!Check([m[@"primaryDrawableUniformStrength"] floatValue]==1.0f &&
               [m[@"originalUniformFresnelGlareStrength"] floatValue]==1.0f &&
               [m[@"primaryPassUniformSHA256"] isEqual:m[@"originalUniformsSHA256"]],
               @"original primary strength remains exactly one")) return NO;
    if (!Check([m[@"variantBytesDifferOnlyAtGate"] boolValue] &&
               [m[@"sameImmutableSourceTextureArgumentForBothVariants"] boolValue] &&
               [m[@"samePipelineObjectAndSamplerObjectAsCallerArguments"] boolValue] &&
               [m[@"auxiliaryTargetsAreDistinctFromDrawable"] boolValue] &&
               ![m[@"drawableReadback"] boolValue],
               @"helper metadata preserves same-source GPU-only gate comparison")) return NO;
    NSDictionary *files=m[@"files"], *hashes=m[@"filesSHA256"];
    if (!Check(files.count==4 && hashes.count==4,@"four output files and four SHA-256 entries")) return NO;
    NSURL *dir=[DocumentsURL() URLByAppendingPathComponent:helper.directoryName isDirectory:YES];
    NSArray *keys=@[@"offRaw",@"onRaw",@"offPNG",@"onPNG"];
    for (NSString *key in keys) {
        NSString *filename=files[key]; NSData *data=filename?[NSData dataWithContentsOfURL:
            [dir URLByAppendingPathComponent:filename]]:nil;
        if (!Check(data.length>0 && [hashes[filename] isEqual:SHA256(data)],
                   [NSString stringWithFormat:@"%@ file exists and SHA-256 matches",key])) return NO;
        if (([key hasSuffix:@"Raw"] && data.length!=132u*132u*4u) ||
            ([key hasSuffix:@"PNG"] && (data.length<8 || memcmp(data.bytes,"\x89PNG\r\n\x1a\n",8)!=0)))
            return Check(NO,[NSString stringWithFormat:@"%@ is well-formed 132x132 output",key]);
    }
    NSURL *manifest=[dir URLByAppendingPathComponent:[stateName stringByAppendingString:@".json"]];
    NSData *disk=[NSData dataWithContentsOfURL:manifest]; NSError *e=nil;
    NSDictionary *persisted=disk?[NSJSONSerialization JSONObjectWithData:disk options:0 error:&e]:nil;
    return Check(persisted && [persisted[@"result"] isEqual:@"GPU_COMPLETED_READBACK_SAVED"] &&
                 [persisted[@"filesSHA256"] isEqual:hashes],
                 @"final per-state metadata persisted beside real outputs");
}

static BOOL TestInjectedCommandFailure(id<MTLDevice> device,id<MTLCommandQueue> queue,
    id<MTLRenderPipelineState> pipeline,id<MTLSamplerState> sampler,
    id<MTLTexture> drawable,id<MTLTexture> source) {
    LGDesignedLightCapture *h=[[LGDesignedLightCapture alloc] init];
    if (!Check(h!=nil,@"command-failure helper init")) return NO;
    // Fault injection is only the helper callback argument: this Metal command really succeeds.
    fprintf(stdout,"INJECTED: GPU command completes successfully; callback is deliberately signaled NO (not a GPU fault).\n");
    LGDesignedLightCaptureRecord *r=EncodeAndWait(h,device,queue,pipeline,sampler,drawable,source,@"idle",501,NO);
    if (!Check(r!=nil,@"command-failure scenario first performs genuine GPU encode and completion")) return NO;
    NSDictionary *suite=[h captureSuiteSnapshot], *m=suite[@"stateResults"][@"idle"];
    if (!Check(![suite[@"pass"] boolValue] && [suite[@"captureSuiteStatus"] isEqual:@"FAIL_CAPTURE_SUITE"] &&
               [m[@"result"] isEqual:@"COMMAND_FAILED"] && ![m[@"commandSucceeded"] boolValue] &&
               ![m[@"capturePass"] boolValue],@"failed completion signal cannot PASS")) return NO;
    NSURL *dir=[DocumentsURL() URLByAppendingPathComponent:h.directoryName isDirectory:YES];
    NSArray *forbidden=@[@"idle-off.bgra",@"idle-on.bgra",@"idle-off.png",@"idle-on.png"];
    for (NSString *n in forbidden)
        if (!Check(![[NSFileManager defaultManager] fileExistsAtPath:
            [[dir URLByAppendingPathComponent:n] path]],@"failed command signal performs no texture readback/PNG write")) return NO;
    NSData *json=[NSData dataWithContentsOfURL:[dir URLByAppendingPathComponent:@"idle.json"]];
    NSDictionary *disk=json?[NSJSONSerialization JSONObjectWithData:json options:0 error:nil]:nil;
    if (!Check([disk[@"result"] isEqual:@"COMMAND_FAILED"] &&
               ![disk[@"capturePass"] boolValue],@"command failure JSON manifest persisted")) return NO;
    fprintf(stdout,"PASS command failure injection\n"); return YES;
}
static BOOL TestFileWriteFailure(id<MTLDevice> device,id<MTLCommandQueue> queue,
    id<MTLRenderPipelineState> pipeline,id<MTLSamplerState> sampler,
    id<MTLTexture> drawable,id<MTLTexture> source) {
    LGDesignedLightCapture *h=[[LGDesignedLightCapture alloc] init];
    if (!Check(h!=nil,@"file-write-failure helper init")) return NO;
    // Remove only this helper instance's own Documents subdirectory.
    NSURL *dir=[DocumentsURL() URLByAppendingPathComponent:h.directoryName isDirectory:YES];
    NSError *e=nil; BOOL removed=[[NSFileManager defaultManager] removeItemAtURL:dir error:&e];
    if (!Check(removed,@"remove only helper-created output directory for write-failure injection")) return NO;
    LGDesignedLightCaptureRecord *r=EncodeAndWait(h,device,queue,pipeline,sampler,drawable,source,@"idle",601,YES);
    if (!Check(r!=nil,@"file-write scenario had real GPU completion")) return NO;
    NSDictionary *suite=[h captureSuiteSnapshot], *m=suite[@"stateResults"][@"idle"];
    if (!Check(![suite[@"pass"] boolValue] && [suite[@"captureSuiteStatus"] isEqual:@"FAIL_CAPTURE_SUITE"] &&
               [m[@"commandSucceeded"] boolValue] && ![m[@"capturePass"] boolValue] &&
               ![m[@"result"] isEqual:@"GPU_COMPLETED_READBACK_SAVED"],
               @"missing output directory/write failure cannot PASS")) return NO;
    if (!Check(![[NSFileManager defaultManager] fileExistsAtPath:dir.path],
               @"write-failure injection did not recreate removed output directory")) return NO;
    fprintf(stdout,"PASS file-write failure injection\n"); return YES;
}
static BOOL TestFourStateRealMetalSuite(id<MTLDevice> device,id<MTLCommandQueue> queue,
    id<MTLRenderPipelineState> pipeline,id<MTLSamplerState> sampler,
    id<MTLTexture> drawable,id<MTLTexture> source) {
    LGDesignedLightCapture *h=[[LGDesignedLightCapture alloc] init];
    if (!Check(h!=nil,@"positive suite helper init")) return NO;
    NSDictionary *initial=[h captureSuiteSnapshot];
    if (!Check(![initial[@"pass"] boolValue] &&
               [initial[@"captureSuiteStatus"] isEqual:@"PENDING_CAPTURE_SUITE"],
               @"empty ledger cannot PASS")) return NO;
    NSArray *first=@[@"idle",@"left",@"right"];
    uint64_t serial=700;
    for (NSString *name in first) {
        LGDesignedLightCaptureRecord *r=EncodeAndWait(h,device,queue,pipeline,sampler,drawable,source,name,serial++,YES);
        if (!Check(r && [r.stateName isEqual:name],@"state claimed and encoded by actual helper")) return NO;
        if (!VerifySavedState(h,name)) return NO;
        NSDictionary *mid=[h captureSuiteSnapshot];
        if (!Check(![mid[@"pass"] boolValue] &&
                   [mid[@"captureSuiteStatus"] isEqual:@"PENDING_CAPTURE_SUITE"] &&
                   [mid[@"stateResults"] count]<4,
                   @"ledger missing any required state cannot PASS")) return NO;
    }
    __block BOOL timedOut=NO;
    LGDLAwaitLedger(h.ledger,NSProcessInfo.processInfo.systemUptime-0.001,^(NSDictionary *incomplete) {
        timedOut=![incomplete[@"pass"] boolValue] && [incomplete[@"captureSuiteStatus"] isEqual:@"FAIL_CAPTURE_TIMEOUT"];
    });
    if (!Check(timedOut,@"missing fourth state finalization deadline yields explicit timeout, never touch PASS")) return NO;
    LGDesignedLightCaptureRecord *release=EncodeAndWait(h,device,queue,pipeline,sampler,drawable,source,@"release",serial,YES);
    if (!Check(release && [release.stateName isEqual:@"release"],@"fourth release state encoded")) return NO;
    NSDictionary *suite=[h captureSuiteSnapshot]; NSDictionary *states=suite[@"stateResults"];
    if (!Check([suite[@"pass"] boolValue] &&
               [suite[@"captureSuiteStatus"] isEqual:@"PASS_ALL_FOUR_GPU_READBACKS_SAVED"] &&
               states.count==4,@"only all four real GPU state results PASS")) return NO;
    for (NSString *name in @[@"idle",@"left",@"right",@"release"])
        if (!VerifySavedState(h,name)) return NO;
    __block BOOL finalized=NO;
    [h finishSuiteWithCompletion:^(NSDictionary *complete) { finalized=[complete[@"pass"] boolValue]; }];
    if (!Check(finalized,@"finalizer accepts only already saved four-state suite")) return NO;
    fprintf(stdout,"PASS four-state actual Metal readback suite: %s\n",
            [DocumentsURL() URLByAppendingPathComponent:h.directoryName].path.UTF8String);
    return YES;
}
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        NSString *bundle=NSBundle.mainBundle.bundleIdentifier?:@"";
        if (argc==2 && strcmp(argv[1],"--expect-init-nil")==0) {
            if (!Check([bundle isEqual:@"org.liquidass.capture-hardening-tests.nonmatch"],
                       @"probe is running inside the deliberate nonmatching host bundle")) return 1;
            LGDesignedLightCapture *h=[[LGDesignedLightCapture alloc] init];
            if (!Check(h==nil,@"ordinary nonmatching bundle must be rejected by unchanged helper gate")) return 1;
            puts("PASS nonmatching bundle init returns nil"); return 0;
        }
        if (!Check([bundle isEqual:@"org.liquidass.native-play-lab"],
                   @"mainBundle must be the exact allowlisted host ID")) return 1;
        if (!TestPrimaryStrengthGate()) return 1;
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        if (!device) { puts("NOT_RUN: MTLCreateSystemDefaultDevice returned nil (exit 77)"); return 77; }
        id<MTLCommandQueue> queue=[device newCommandQueue];
        id<MTLRenderPipelineState> pipeline=nil; id<MTLSamplerState> sampler=nil;
        if (!Check(queue!=nil,@"Metal command queue created") || !MakePipeline(device,&pipeline,&sampler)) return 1;
        id<MTLTexture> source=MakeSource(device), drawable=MakePrimaryTarget(device);
        if (!Check(source!=nil && drawable!=nil,@"real fixed source and mock primary textures allocated")) return 1;
        if (!TestInjectedCommandFailure(device,queue,pipeline,sampler,drawable,source)) return 1;
        if (!TestFileWriteFailure(device,queue,pipeline,sampler,drawable,source)) return 1;
        if (!TestFourStateRealMetalSuite(device,queue,pipeline,sampler,drawable,source)) return 1;
        puts("PASS all Mac-only Metal capture regressions"); return 0;
    }
}
