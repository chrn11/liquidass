// Included by CAClosedRegression.mm after Draw/Compare/CaseFile; fault injection only.
static bool TestAuditFailClosed(NSString *outRoot,id<MTLDevice> device,id<MTLCommandQueue> queue,
    LGCAClosedProfileRuntime *runtime,id<MTLRenderPipelineState> oldPipeline,id<MTLTexture> glyph) {
    const NSUInteger w=132,h=132;auto pixels=MakeGrid(w,h);
    id<MTLTexture> source=MakeSource(device,w,h,pixels);if(!source)return false;
    NSError *error=nil;id<MTLLibrary> lib=[device newLibraryWithSource:
        [NSString stringWithUTF8String:kLGCAClosedProfileMSL] options:nil error:&error];
    id<MTLFunction> a=[lib newFunctionWithName:@"LGCAAuditOpaque"], f=[lib newFunctionWithName:@"LGCAFinalizeOpaque"];
    if(!a||!f)return false;
    id<MTLComputePipelineState> scan=[device newComputePipelineStateWithFunction:a error:&error];
    id<MTLComputePipelineState> final=[device newComputePipelineStateWithFunction:f error:&error];
    if(!scan||!final)return false;
    LGCAClosedTestUniforms u=Uniforms(w,h,w,h,2,0);NSMutableArray *records=[NSMutableArray array];bool all=true;
    for(unsigned mode=0;mode<5;mode++) {
        NSString *name=@[@"unrun-deny-zero",@"incomplete-count",@"full-count-no-finalizer",@"partial-GPU-scan-finalized",@"no-scan-finalized"][mode];
        id<MTLBuffer> token=[device newBufferWithLength:4 options:MTLResourceStorageModeShared|MTLResourceHazardTrackingModeTracked];if(!token)return false;
        uint32_t initial=mode==1?uint32_t(w*h-1):(mode==2?uint32_t(w*h):0u);memcpy(token.contents,&initial,4);
        NSString *auditStatus=@"INTENTIONAL_CPU_TOKEN_FAULT_NO_GPU_SCAN";
        if(mode>=3) {
            id<MTLCommandBuffer> cb=[queue commandBuffer];if(!cb)return false;
            if(mode==3) {
                id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];if(!e)return false;
                [e setComputePipelineState:scan];[e setTexture:source atIndex:0];[e setBuffer:token offset:0 atIndex:1];
                // Intentionally omit four rows/columns: 128² completed, not132².
                [e dispatchThreadgroups:MTLSizeMake(16,16,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[e endEncoding];
            }
            id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];if(!e)return false;
            [e setComputePipelineState:final];[e setTexture:source atIndex:0];[e setBuffer:token offset:0 atIndex:1];
            [e dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[e endEncoding];
            [cb commit];[cb waitUntilCompleted];auditStatus=StatusName(cb.status);if(cb.status!=MTLCommandBufferStatusCompleted)return false;
        }
        uint32_t actual=0;memcpy(&actual,token.contents,4);
        RenderResult old=Draw(device,queue,runtime,oldPipeline,source,glyph,u,w,h,false);
        RenderResult rejected=Draw(device,queue,runtime,oldPipeline,source,glyph,u,w,h,false,token);
        auto diff=Compare(old.pixels,rejected.pixels);
        bool ok=actual!=kLGCAOpaqueAcceptMagic && old.pixels.size()==w*h*4 && rejected.pixels.size()==w*h*4 &&
            diff.differentBytes==0 && [old.commandStatus isEqual:@"completed"] && [rejected.commandStatus isEqual:@"completed"];
        NSString *stem=[@"audit-fault-" stringByAppendingString:name];
        bool saved=WriteBytes(Path(Path(outRoot,@"rawBGRA"),[stem stringByAppendingString:@".old.bgra"]),old.pixels.data(),old.pixels.size()) &&
            WriteBytes(Path(Path(outRoot,@"rawBGRA"),[stem stringByAppendingString:@".profile.bgra"]),rejected.pixels.data(),rejected.pixels.size());
        [records addObject:@{@"case":stem,@"status":(ok&&saved)?@"PASS":@"FAIL",@"initialToken":@(initial),@"actualFinalToken":@(actual),
            @"faultInjectionNotProduction":@YES,@"auditCommandStatus":auditStatus,@"oldCommandStatus":old.commandStatus?:@"missing",
            @"profileCommandStatus":rejected.commandStatus?:@"missing",@"maxByteDelta":@(diff.maxByteDiff),@"differentBytes":N(diff.differentBytes),
            @"uniformSHA256":HexSHA256(&u,sizeof(u)),@"sourceSHA256":HexSHA256(pixels.data(),pixels.size())}];
        all=all&&ok&&saved;
    }
    return WriteJSON(CaseFile(outRoot,@"audit-failclosed.json"),@{@"status":all?@"PASS":@"FAIL",@"cases":records,@"scope":@"Explicit token/missing/partial-audit fault injection; output always real Metal"})&&all;
}

static bool TestResourceRejections(NSString *outRoot,id<MTLDevice> device,id<MTLCommandQueue> queue,LGCAClosedProfileRuntime *runtime) {
    auto pixels=MakeGrid(132,132);id<MTLTexture> source=MakeSource(device,132,132,pixels),dest=MakeColorTarget(device,132,132);
    if(!source||!dest)return false;
    bool aliasRejected=!LGCAClosedTexturesAreDisjoint(source,source),disjointAccepted=LGCAClosedTexturesAreDisjoint(source,dest);
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB width:132 height:132 mipmapped:YES];
    d.usage=MTLTextureUsageShaderRead;d.storageMode=MTLStorageModeShared;id<MTLTexture> mip=[device newTextureWithDescriptor:d];
    if(!mip||mip.mipmapLevelCount<=1)return false;
    id<MTLCommandBuffer> cb=[queue commandBuffer];NSDictionary *before=Pool(runtime);
    LGCAClosedAuditLease *lease=[runtime encodeAuditForSource:mip command:cb];NSDictionary *after=Pool(runtime);
    [cb commit];[cb waitUntilCompleted];bool ok=aliasRejected&&disjointAccepted&&!lease&&[before isEqual:after]&&cb.status==MTLCommandBufferStatusCompleted;
    return WriteJSON(CaseFile(outRoot,@"resource-rejections.json"),@{@"status":ok?@"PASS":@"FAIL",@"sameTextureRejected":@(aliasRejected),@"distinctNonAliasedTargetsAccepted":@(disjointAccepted),@"multipleMipLevelsRejected":@(!lease),@"mipCount":@(mip.mipmapLevelCount),@"poolBefore":before,@"poolAfter":after})&&ok;
}

static bool TestSnapshotStability(NSString *outRoot,id<MTLDevice> device,id<MTLCommandQueue> queue,
    LGCAClosedProfileRuntime *runtime,id<MTLRenderPipelineState> oldPipeline,id<MTLTexture> glyph) {
    auto opaque=MakeGrid(132,132),changed=opaque;
    for(size_t i=0;i<changed.size();i+=4){changed[i]=12;changed[i+1]=25;changed[i+2]=55;changed[i+3]=128;}
    id<MTLTexture> referenceSource=MakeSource(device,132,132,opaque),liveSource=MakeSource(device,132,132,opaque),mutation=MakeSource(device,132,132,changed);
    if(!referenceSource||!liveSource||!mutation)return false;
    LGCAClosedTestUniforms u=Uniforms(132,132,132,132,2,1);
    RenderResult expected=Draw(device,queue,runtime,oldPipeline,referenceSource,glyph,u,132,132,true);
    RenderResult actual=Draw(device,queue,runtime,oldPipeline,liveSource,glyph,u,132,132,true,nil,mutation);
    std::vector<uint8_t> after(changed.size());[liveSource getBytes:after.data() bytesPerRow:132*4 fromRegion:MTLRegionMake2D(0,0,132,132) mipmapLevel:0];
    auto diff=Compare(expected.pixels,actual.pixels);
    bool released=actual.lease.sourceTexture==nil;
    // Draw holds a temporary sampledSource strongly until return, then only weak lease remains.
    // ARC autorelease lifetime may extend to this pool; production slot snapshot is what must clear.
    for(unsigned spin=0;spin<500 && [[Pool(runtime) objectForKey:@"busyCount"] unsignedIntegerValue]!=0;spin++)
        [NSThread sleepForTimeInterval:0.001];
    bool slotsReleased=[[Pool(runtime) objectForKey:@"busyCount"] unsignedIntegerValue]==0 &&
        [[Pool(runtime) objectForKey:@"ownedSnapshotCount"] unsignedIntegerValue]==0;
    bool ok=expected.pixels.size()==132*132*4 && actual.pixels.size()==132*132*4 && diff.differentBytes==0 && after==changed &&
        expected.usedProfile && actual.usedProfile && expected.auditFlag==kLGCAOpaqueAcceptMagic && actual.auditFlag==kLGCAOpaqueAcceptMagic &&
        [expected.commandStatus isEqual:@"completed"] && [actual.commandStatus isEqual:@"completed"] && slotsReleased;
    bool saved=WriteBytes(Path(Path(outRoot,@"rawBGRA"),@"snapshot-stability.expected-profile.bgra"),expected.pixels.data(),expected.pixels.size()) &&
        WriteBytes(Path(Path(outRoot,@"rawBGRA"),@"snapshot-stability.actual-profile.bgra"),actual.pixels.data(),actual.pixels.size()) &&
        WriteBytes(Path(Path(outRoot,@"rawBGRA"),@"snapshot-stability.mutated-original.bgra"),after.data(),after.size());
    return WriteJSON(CaseFile(outRoot,@"snapshot-stability.json"),@{@"status":(ok&&saved)?@"PASS":@"FAIL",@"originalActuallyMutatedAfterAudit":@(after==changed),
        @"auditedSnapshotOutputUnchanged":@(diff.differentBytes==0),@"actualAuditToken":@(actual.auditFlag),@"maxByteDelta":@(diff.maxByteDiff),
        @"differentBytes":N(diff.differentBytes),@"commandsCompleted":@([expected.commandStatus isEqual:@"completed"]&&[actual.commandStatus isEqual:@"completed"]),
        @"slotsReleased":@(slotsReleased),@"weakSnapshotCurrentlyNil":@(released),@"poolAfter":Pool(runtime),@"faultInjectionScope":@"Same-command original texture overwritten by real GPU blit after audit/finalize and before fragment; profile samples its own immutable copy, not a simulation of arbitrary cross-queue scheduling"})&&ok&&saved;
}
