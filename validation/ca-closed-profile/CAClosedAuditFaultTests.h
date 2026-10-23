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
