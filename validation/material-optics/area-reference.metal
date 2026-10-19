/* Review-only pixel-area integration of the identical optical map, not a
 * production sampling path and not an Apple reference. Piecewise-constant
 * source texels + nearest sampling avoid adding another linear-filter blur
 * while integrating a target pixel. Both8x8 and16x16 are kept for convergence.
 */
float4 reviewAreaPoint(texture2d<float, access::sample> src,constant Uniforms &u,float2 p) {
    constexpr sampler nearestSource(filter::nearest,address::clamp_to_edge);
    LGButtonOpticsResult q=localButtonEvaluateAt(p,u.resolution.x,u.resolution.y,u.bezelWidth,u);
    float2 flatUV=localButtonSourceUV(src,u,p/u.resolution);
    if(!q.valid||q.signedDistance>=0.0f)return src.sample(nearestSource,flatUV,level(0.0f));
    float2 primary=localButtonCandidateTargetUV(q,p,false,u);
    float2 secondary=localButtonCandidateTargetUV(q,p,true,u);
    float4 a=src.sample(nearestSource,localButtonSourceUV(src,u,primary),level(0.0f));
    if(a.a<.01f)a=src.sample(nearestSource,flatUV,level(0.0f));
    float4 b=src.sample(nearestSource,localButtonSourceUV(src,u,secondary),level(0.0f));
    if(b.a<.01f)b=a;
    float w=clamp(q.environmentWeight,0.0f,.28f);
    float3 c=float3(LGBOEnvironmentMixPremultipliedChannel(a.r,a.a,b.r,b.a,w),
      LGBOEnvironmentMixPremultipliedChannel(a.g,a.a,b.g,b.a,w),
      LGBOEnvironmentMixPremultipliedChannel(a.b,a.a,b.b,b.a,w));
    return float4(c,a.a);
}
float4 reviewPixelArea(texture2d<float, access::sample> src,constant Uniforms &u,float2 center,int divisions) {
    float4 sum=float4(0.0f);
    for(int y=0;y<divisions;y++)for(int x=0;x<divisions;x++) {
        float2 delta=(float2(x,y)+.5f)/(float)divisions-.5f;
        sum+=reviewAreaPoint(src,u,center+delta);
    }
    return sum/(float)(divisions*divisions);
}
fragment float4 reviewArea8(LGVertexOut in [[stage_in]],texture2d<float,access::sample> src [[texture(0)]],constant Uniforms &u [[buffer(0)]]) {
    return reviewPixelArea(src,u,in.position.xy,8);
}
fragment float4 reviewArea16(LGVertexOut in [[stage_in]],texture2d<float,access::sample> src [[texture(0)]],constant Uniforms &u [[buffer(0)]]) {
    return reviewPixelArea(src,u,in.position.xy,16);
}
