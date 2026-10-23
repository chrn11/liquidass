#pragma once
#ifndef LG_CA_CLOSED_PROFILE_COMPILED
#define LG_CA_CLOSED_PROFILE_COMPILED 0
#endif
#if LG_CA_CLOSED_PROFILE_COMPILED == 1
/* Single-TU runtime for the optional CA profile. Never retains origTex or a CA
 * context outside its original command; three 4-byte audit slots are bounded. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#import <CommonCrypto/CommonDigest.h>
#import "LGCAClosedProfileShaderSource.h"
#include <string.h>
NS_ASSUME_NONNULL_BEGIN
static const uint32_t kLGCAOpaqueAcceptMagic=0x4c474341u;
/* Conservative disjoint-resource proof for this opt-in only; unsupported views,
 * heap aliases and buffer-backed textures keep the unchanged original pipeline. */
static BOOL LGCAClosedTexturesAreDisjoint(id<MTLTexture> source,id<MTLTexture> destination) {
    if (!source || !destination || source==destination || source.device!=destination.device ||
        source.parentTexture || destination.parentTexture || source.buffer || destination.buffer ||
        source.heap || destination.heap || source.framebufferOnly ||
        source.hazardTrackingMode==MTLHazardTrackingModeUntracked ||
        destination.hazardTrackingMode==MTLHazardTrackingModeUntracked) return NO;
    IOSurfaceRef a=source.iosurface,b=destination.iosurface;
    if (a && b && IOSurfaceGetID(a)==IOSurfaceGetID(b)) return NO;
    return YES;
}
@interface LGCAClosedAuditLease : NSObject
@property(nonatomic,strong,readonly) id<MTLBuffer> buffer;
// Weak after completion: a retained lease must not cache source pixels.
@property(nonatomic,weak,readonly,nullable) id<MTLTexture> sourceTexture;
- (instancetype)initWithBuffer:(id<MTLBuffer>)buffer sourceTexture:(id<MTLTexture>)snapshot;
@end
@implementation LGCAClosedAuditLease
- (instancetype)initWithBuffer:(id<MTLBuffer>)buffer sourceTexture:(id<MTLTexture>)snapshot {
    if ((self=[super init])) { _buffer=buffer; _sourceTexture=snapshot; } return self;
}
@end
@interface LGCAAuditSlot : NSObject
@property(nonatomic,strong) id<MTLBuffer> buffer;
@property(nonatomic) BOOL busy;
@property(nonatomic) uint64_t generation;
@property(nonatomic,strong,nullable) id<MTLTexture> snapshot;
@end
@implementation LGCAAuditSlot @end
@interface LGCAClosedProfileRuntime : NSObject
@property(nonatomic,strong,readonly) id<MTLRenderPipelineState> renderPipeline;
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device;
- (nullable LGCAClosedAuditLease *)encodeAuditForSource:(id<MTLTexture>)source
    command:(id<MTLCommandBuffer>)command;
- (NSDictionary *)poolSnapshot;
@end
@interface LGCAClosedProfileRuntime ()
@property(nonatomic,strong) id<MTLDevice> device;
@property(nonatomic,strong,readwrite) id<MTLRenderPipelineState> renderPipeline;
@property(nonatomic,strong) id<MTLComputePipelineState> auditPipeline;
@property(nonatomic,strong) id<MTLComputePipelineState> finalizePipeline;
@property(nonatomic,strong) NSArray<LGCAAuditSlot *> *slots;
@end
@implementation LGCAClosedProfileRuntime
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device {
    if (!device || !(self=[super init])) return nil;
    _device=device;
    NSData *bytes=[NSData dataWithBytes:kLGCAClosedProfileMSL length:strlen(kLGCAClosedProfileMSL)];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,hash);
    char actual[65];static const char hex[]="0123456789abcdef";
    for (unsigned i=0;i<sizeof(hash);i++){actual[2*i]=hex[hash[i]>>4];actual[2*i+1]=hex[hash[i]&15];}actual[64]=0;
    if (strcmp(actual,kLGCAClosedProfileMSLSHA256)!=0) return nil;
    NSString *source=[[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
    NSError *error=nil;id<MTLLibrary> lib=[device newLibraryWithSource:source options:nil error:&error];
    if (!lib) return nil;
    id<MTLFunction> vertex=[lib newFunctionWithName:@"liquidGlassVertex"];
    id<MTLFunction> fragment=[lib newFunctionWithName:@"liquidGlassCAClosedFragment"];
    id<MTLFunction> audit=[lib newFunctionWithName:@"LGCAAuditOpaque"];
    id<MTLFunction> finalize=[lib newFunctionWithName:@"LGCAFinalizeOpaque"];
    if (!vertex || !fragment || !audit || !finalize) return nil;
    MTLRenderPipelineDescriptor *p=[MTLRenderPipelineDescriptor new];
    p.label=@"LiquidAss optional closed CA profile (opaque sRGB only)";
    p.vertexFunction=vertex;p.fragmentFunction=fragment;
    p.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm_sRGB;
    /* Preserve CA overwrite semantics: original pipeline has blending disabled. */
    p.colorAttachments[0].blendingEnabled=NO;
    _renderPipeline=[device newRenderPipelineStateWithDescriptor:p error:&error];
    _auditPipeline=[device newComputePipelineStateWithFunction:audit error:&error];
    _finalizePipeline=[device newComputePipelineStateWithFunction:finalize error:&error];
    if (!_renderPipeline || !_auditPipeline || !_finalizePipeline ||
        _auditPipeline.maxTotalThreadsPerThreadgroup<64) return nil;
    NSMutableArray *slots=[NSMutableArray arrayWithCapacity:3];
    for (unsigned i=0;i<3;i++) {
        LGCAAuditSlot *slot=[LGCAAuditSlot new];
        slot.buffer=[device newBufferWithLength:sizeof(uint32_t) options:MTLResourceStorageModeShared|MTLResourceHazardTrackingModeTracked];
        if (!slot.buffer) return nil;
        *(uint32_t *)slot.buffer.contents=0u;[slots addObject:slot];
    }
    _slots=[slots copy];return self;
}
- (NSDictionary *)poolSnapshot {
    @synchronized(self) {
        NSUInteger busy=0,copies=0;for (LGCAAuditSlot *slot in self.slots) {
            busy+=slot.busy?1u:0u;copies+=slot.snapshot?1u:0u;
        }
        return @{@"busyCount":@(busy),@"slotCount":@(self.slots.count),@"ownedSnapshotCount":@(copies),
            @"retainsOriginalSourceUntilCommandCompletion":@(busy>0),
            @"retainsOriginalSourceAfterCompletion":@NO,
            @"ownedSnapshotMaximumInFlight":@3,@"ownedSnapshotReleasedOnCompletion":@YES};
    }
}
- (nullable LGCAClosedAuditLease *)encodeAuditForSource:(id<MTLTexture>)source
    command:(id<MTLCommandBuffer>)command {
    if (!source || !command || source.device!=self.device || command.commandQueue.device!=self.device ||
        (command.status!=MTLCommandBufferStatusNotEnqueued && command.status!=MTLCommandBufferStatusEnqueued) ||
        source.pixelFormat!=MTLPixelFormatBGRA8Unorm_sRGB || source.textureType!=MTLTextureType2D ||
        source.sampleCount!=1 || source.mipmapLevelCount!=1 || source.parentTexture || source.buffer || source.heap ||
        source.framebufferOnly || source.hazardTrackingMode==MTLHazardTrackingModeUntracked ||
        source.width<22 || source.height<22 || source.width>176 || source.height>176 ||
        (source.usage!=MTLTextureUsageUnknown && !(source.usage&MTLTextureUsageShaderRead))) return nil;
    LGCAAuditSlot *selected=nil;
    @synchronized(self) {
        for (LGCAAuditSlot *slot in self.slots) if (!slot.busy && slot.generation<UINT64_MAX) {
            slot.busy=YES;slot.generation++;selected=slot;break;
        }
    }
    if (!selected) return nil;
    /* Register completion BEFORE any encoding. Even an encoder failure after a
     * GPU clear must not recycle the slot while that command can still write it.
     * An abandoned/uncommitted command can consume one slot, never unbounded memory. */
    LGCAAuditSlot *retainedSlot=selected;const uint64_t generation=selected.generation;
    /* The original CA command may use unretained references. Keep only this
     * exact source alive until that same command finishes; never cache it. */
    id<MTLTexture> sourceUntilCommandCompletion=source;
    [command addCompletedHandler:^(__unused id<MTLCommandBuffer> completed) {
        (void)sourceUntilCommandCompletion.width;
        @synchronized(self) { if (retainedSlot.generation==generation) {
            retainedSlot.snapshot=nil;retainedSlot.busy=NO;
        } }
    }];
    MTLTextureDescriptor *snapshotDescriptor=[MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
        width:source.width height:source.height mipmapped:NO];
    snapshotDescriptor.storageMode=MTLStorageModePrivate;
    snapshotDescriptor.hazardTrackingMode=MTLHazardTrackingModeTracked;
    snapshotDescriptor.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> snapshot=[self.device newTextureWithDescriptor:snapshotDescriptor];
    if (!snapshot) return nil;
    selected.snapshot=snapshot; // slot and original command own it only until completion
    *(uint32_t *)selected.buffer.contents=0u; // DENY/PENDING; only finalizer can write ACCEPT_MAGIC.
    id<MTLBlitCommandEncoder> clear=[command blitCommandEncoder];
    if (!clear) return nil;
    [clear fillBuffer:selected.buffer range:NSMakeRange(0,sizeof(uint32_t)) value:0];
    [clear copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(source.width,source.height,1) toTexture:snapshot
        destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [clear endEncoding];
    id<MTLComputeCommandEncoder> audit=[command computeCommandEncoder];
    if (!audit) return nil;
    [audit setComputePipelineState:self.auditPipeline];
    [audit setTexture:snapshot atIndex:0];[audit setBuffer:selected.buffer offset:0 atIndex:1];
    [audit dispatchThreadgroups:MTLSizeMake((source.width+7u)/8u,(source.height+7u)/8u,1)
        threadsPerThreadgroup:MTLSizeMake(8,8,1)];
    [audit endEncoding];
    /* Separate encoders plus a tracked buffer provide scan -> finalize -> draw
     * dependencies. Zero, incomplete counts and BAD never authorize a fragment. */
    id<MTLComputeCommandEncoder> finalize=[command computeCommandEncoder];
    if (!finalize) return nil;
    [finalize setComputePipelineState:self.finalizePipeline];
    [finalize setTexture:snapshot atIndex:0];[finalize setBuffer:selected.buffer offset:0 atIndex:1];
    [finalize dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
    [finalize endEncoding];
    return [[LGCAClosedAuditLease alloc] initWithBuffer:selected.buffer sourceTexture:snapshot];
}
@end
/* Only one physical device is accepted by this optional cache. Original CA
 * renderer remains the fallback on allocation/compile failure or device drift. */
static LGCAClosedProfileRuntime * _Nullable LGCAClosedRuntimeForDevice(id<MTLDevice> device) {
    static id<MTLDevice> selectedDevice=nil;
    static LGCAClosedProfileRuntime *runtime=nil;static BOOL attempted=NO;
    @synchronized(LGCAClosedProfileRuntime.class) {
        if (!attempted) { attempted=YES;selectedDevice=device;runtime=[[LGCAClosedProfileRuntime alloc] initWithDevice:device]; }
        return device==selectedDevice?runtime:nil;
    }
}
NS_ASSUME_NONNULL_END
#endif
