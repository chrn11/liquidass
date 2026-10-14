#include <metal_stdlib>
using namespace metal;

// Boundary path envelope: zero at the dome/mask boundary, saturated inward.

// ABI mirrors PlayUniforms in NativePlayLabViewController.m exactly (80 bytes).
struct PlayUniforms {
    float4 viewportPress; // drawable width, height, press, interactive
    float4 touchBezel;    // logical x, y, bezel, thickness
    float4 optics;        // IOR, blur, tint, glare
    float4 effects;       // visibility, blur stage, refraction stage, tint stage
    uint4 flags;          // highlight stage, debug UV, candidate B, reserved
};
struct PlayVertexOut { float4 position [[position]]; };

vertex PlayVertexOut playVertex(uint id [[vertex_id]]) {
    constexpr float2 vertices[3]={{-1.0,-1.0},{3.0,-1.0},{-1.0,3.0}};
    PlayVertexOut out; out.position=float4(vertices[id],0.0,1.0); return out;
}

float sdRounded(float2 p,float2 halfSize,float radius) {
    float2 q=abs(p)-halfSize+float2(radius);
    return length(max(q,float2(0.0)))+min(max(q.x,q.y),0.0)-radius;
}
float capsuleSD(float2 p,constant PlayUniforms &u) {
    float press=u.viewportPress.z*u.viewportPress.w;
    float2 touch=u.touchBezel.xy;
    float2 center=float2(PLAY_CENTER_X,PLAY_CENTER_Y)+clamp(touch-float2(PLAY_CENTER_X,PLAY_CENTER_Y),float2(-80.0,-60.0),float2(80.0,60.0))*press*.035;
    float2 stretch=float2(1.0+.025*press,1.0-.055*press);
    float2 q=(p-center)/stretch;
    float2 localTouch=(touch-center)/stretch;
    float2 contact=q-localTouch;
    float flex=press*exp(-dot(contact,contact)/5400.0);
    return sdRounded(q,float2(PLAY_CAPSULE_HALF_WIDTH,PLAY_CAPSULE_HALF_HEIGHT),PLAY_CAPSULE_RADIUS)*min(stretch.x,stretch.y)-flex*2.1;
}
float3 capsuleDome(float2 p,constant PlayUniforms &u) {
    float press=u.viewportPress.z*u.viewportPress.w;
    float2 touch=u.touchBezel.xy;
    float2 center=float2(PLAY_CENTER_X,PLAY_CENTER_Y)+clamp(touch-float2(PLAY_CENTER_X,PLAY_CENTER_Y),float2(-80.0,-60.0),float2(80.0,60.0))*press*.035;
    float2 stretch=float2(1.0+.025*press,1.0-.055*press);
    float2 local=(p-center)/stretch;
    float2 radial=float2(local.x-clamp(local.x,-PLAY_DOME_STRAIGHT_HALF,PLAY_DOME_STRAIGHT_HALF),local.y);
    float2 contact=local-(touch-center)/stretch;
    float flex=press*exp(-dot(contact,contact)/5400.0);
    float bulge=2.1*flex/min(stretch.x,stretch.y);
    float radius=PLAY_DOME_RADIUS+bulge;
    float2 radiusGradient=-contact*(2.0*bulge/5400.0);
    float radialSquared=dot(radial,radial);
    float q=clamp(1.0-radialSquared/(radius*radius),0.0,1.0);
    float regularizer=PLAY_DOME_REGULARIZER;
    float denominator=sqrt(1.0+regularizer*regularizer)-regularizer;
    float root=sqrt(q+regularizer*regularizer);
    float amplitude=min(PLAY_HEIGHT_MAX_PX,u.touchBezel.z*PLAY_HEIGHT_BEZEL_GAIN+u.touchBezel.w*PLAY_HEIGHT_THICKNESS_GAIN);
    float baseHeight=amplitude*(root-regularizer)/denominator;
    float2 baseSlope=amplitude*(radial/(radius*radius)-radialSquared*radiusGradient/(radius*radius*radius))/(denominator*root);
    float axialRadius=PLAY_AXIAL_RADIUS;
    float axialQ=clamp(1.0-pow(local.x/axialRadius,2.0),0.0,1.0);
    float axialRoot=sqrt(axialQ+regularizer*regularizer);
    float axial=(axialRoot-regularizer)/denominator;
    float axialTilt=local.x/(axialRadius*axialRadius*axialRoot*denominator);
    float2 slope=float2((axial*baseSlope.x+baseHeight*axialTilt)/stretch.x,axial*baseSlope.y/stretch.y);
    // Returned XY are the front-facing graph normal: -d(height)/d(screen XY).
    return float3(slope,baseHeight*axial);
}
float3 sourceAt(float2 p,constant PlayUniforms &u,texture2d<float> input,sampler linearClamp) {
    float2 size=float2(PLAY_INPUT_WIDTH,PLAY_INPUT_HEIGHT);
    float2 uv=clamp(p/size,float2(.5)/size,float2(1.0)-float2(.5)/size);
    // RGBA8Unorm_sRGB filtering decodes each texel to linear before filtering,
    // matching Web's explicit sRGB decode-before-bilinear requirement.
    return input.sample(linearClamp,uv).rgb;
}
float lightBox(float2 angular,float2 center,float2 halfSize,float feather) {
    float2 q=abs(angular-center)-halfSize;
    float distance=length(max(q,float2(0.0)))+min(max(q.x,q.y),0.0);
    return 1.0-smoothstep(-feather,feather,distance);
}
float3 blurred(float2 p,float radius,constant PlayUniforms &u,texture2d<float> input,sampler linearClamp) {
    if(radius<.01) return sourceAt(p,u,input,linearClamp);
    float3 c=sourceAt(p,u,input,linearClamp)*.24;
    c+=sourceAt(p+float2(radius,0),u,input,linearClamp)*.12+sourceAt(p-float2(radius,0),u,input,linearClamp)*.12;
    c+=sourceAt(p+float2(0,radius),u,input,linearClamp)*.12+sourceAt(p-float2(0,radius),u,input,linearClamp)*.12;
    c+=sourceAt(p+float2(radius,radius),u,input,linearClamp)*.07+sourceAt(p-float2(radius,radius),u,input,linearClamp)*.07;
    c+=sourceAt(p+float2(radius,-radius),u,input,linearClamp)*.07+sourceAt(p+float2(-radius,radius),u,input,linearClamp)*.07;
    return c;
}

fragment float4 playFragment(PlayVertexOut in [[stage_in]], constant PlayUniforms &u [[buffer(0)]], texture2d<float> input [[texture(0)]], sampler linearClamp [[sampler(0)]]) {
    float2 logical=in.position.xy/float2(u.viewportPress.xy)*float2(PLAY_INPUT_WIDTH,PLAY_INPUT_HEIGHT);
    float3 original=sourceAt(logical,u,input,linearClamp);
    if(u.flags.z==0) return float4(original,1.0);
    float d=capsuleSD(logical,u);
    float coverage=floor((1.0-smoothstep(-.65,.65,d))*255.0+.5)/255.0;
    if(coverage<=0.0) {
        if(u.flags.y!=0) return float4(.5,.5,0.0,1.0);
        return float4(original,1.0);
    }
    float2 grad=float2(capsuleSD(logical+float2(1,0),u)-capsuleSD(logical-float2(1,0),u),capsuleSD(logical+float2(0,1),u)-capsuleSD(logical-float2(0,1),u));
    float gradLength=length(grad); float2 outward=gradLength>.0001?grad/gradLength:float2(0.0);
    float depth=max(-d,0.0);
    float response=clamp(u.effects.x,0.0,1.0);
    float press=u.viewportPress.z*u.viewportPress.w;
    float width=u.touchBezel.z*(.8+u.touchBezel.w*.02);
    float q=clamp(depth/max(width,1.0),0.0,1.0);
    float curvedHeight=sqrt(max(q*(2.0-q),0.0));
    float rawSlope=(1.0-q)/max(curvedHeight,.20);
    float slope=rawSlope/sqrt(1.0+rawSlope*rawSlope/9.0);
    float2 surfaceSlope=outward*slope;
    float localHeight=curvedHeight*width*.6;
    float3 dome=capsuleDome(logical,u); surfaceSlope=dome.xy; localHeight=dome.z;
    surfaceSlope*=response;
    float2 transportSlope=surfaceSlope;
    float2 fromTouch=logical-u.touchBezel.xy;
    float indentation=exp(-dot(fromTouch,fromTouch)/6400.0)*press;
    transportSlope-=fromTouch*(.0016*indentation)*response;
    float3 surfaceNormal=normalize(float3(surfaceSlope,1.0));
    float ior=max(u.optics.x,1.0);
    float lensScale=clamp(u.touchBezel.w/10.0,0.0,1.6);
    // Candidate-11 transport uses a steeper powered face, still one bounded entry ray.
    float3 transportNormal=normalize(float3(transportSlope*lensScale*PLAY_TRANSPORT_SLOPE_SCALE,1.0));
    float3 transmittedRay=refract(float3(0.0,0.0,-1.0),transportNormal,1.0/ior);
    // One powered entry surface projects the ray to a virtual image plane 88 px behind it.
    // This explicit screen-space model is not an Apple/Liquidify algorithm claim.
    float pathEnvelope=smoothstep(0.0,PLAY_PATH_FADE_HEIGHT_PX,max(localHeight,0.0));
    float projectionDepth=(max(u.touchBezel.w,0.0)+max(localHeight,0.0)+PLAY_VIRTUAL_IMAGE_GAP_PX)*pathEnvelope;
    float2 opticalOffset=transmittedRay.xy/max(-transmittedRay.z,.25)*projectionDepth;
    float offsetLength=length(opticalOffset);
    opticalOffset/=sqrt(1.0+offsetLength*offsetLength/(PLAY_REFRACTION_LIMIT_PX*PLAY_REFRACTION_LIMIT_PX));
    opticalOffset*=u.effects.z;
    float2 sourceMin=float2(.5), sourceMax=float2(PLAY_INPUT_WIDTH,PLAY_INPUT_HEIGHT)-float2(.5);
    opticalOffset=clamp(logical+opticalOffset,sourceMin,sourceMax)-logical;
    if(u.flags.y!=0) return float4(float2(.5)+opticalOffset/PLAY_UV_DECODE_SCALE,coverage,1.0);
    float3 background=original;
    float scattering=u.optics.y*u.effects.y;
    float3 glass=blurred(logical+opticalOffset,scattering,u,input,linearClamp);
    glass=mix(glass,float3(1.0),clamp(u.optics.z,0.0,.2)*u.effects.w);
    float cosI=clamp(surfaceNormal.z,0.0,1.0);
    float cosT=sqrt(max(1.0-(1.0-cosI*cosI)/(ior*ior),0.0));
    float rs=(cosI-ior*cosT)/max(cosI+ior*cosT,.001);
    float rp=(ior*cosI-cosT)/max(ior*cosI+cosT,.001);
    float fresnel=(rs*rs+rp*rp)*.5;
    // Reflection comes from a bounded virtual area emitter; colored edge lobes
    // are directional angular panels, never a sample/overlay at fixed source pixels.
    float2 lightShift=clamp((u.touchBezel.xy-float2(PLAY_CENTER_X,PLAY_CENTER_Y))/float2(PLAY_INPUT_WIDTH,PLAY_INPUT_HEIGHT),float2(-.5),float2(.5))*press*.36;
    float3 reflectedRay=reflect(float3(0.0,0.0,-1.0),surfaceNormal);
    float2 angular=reflectedRay.xy/(abs(reflectedRay.z)+.45);
    float2 panelDirection=float2(-.08,-.18)+lightShift*.65;
    float panelArea=lightBox(angular,panelDirection,float2(.70,.54),.20);
    float coolPanel=lightBox(angular,float2(-.46,-.29)+lightShift,float2(.18,.11),.09);
    float warmPanel=lightBox(angular,float2(.42,.20)-lightShift*.5,float2(.18,.12),.09);
    float thicknessGate=smoothstep(0.0,1.0,max(u.touchBezel.w,0.0));
    float highlightStage=(u.flags.x!=0 && u.flags.z!=0)?1.0:0.0;
    float surfaceGate=thicknessGate*highlightStage*clamp(u.optics.w,0.0,1.0)*response;
    float reflectance=clamp(fresnel*surfaceGate*panelArea,0.0,1.0);
    float3 virtualHDRRadiance=float3(2.70,2.66,2.58);
    float exposure=.58;
    float3 exposedRadiance=virtualHDRRadiance*exposure;
    glass=mix(glass,exposedRadiance,reflectance);
    float3 coolRadiance=float3(.24,.72,1.55);
    float3 warmRadiance=float3(1.55,.74,.19);
    glass+=(coolRadiance*coolPanel+warmRadiance*warmPanel)*fresnel*surfaceGate*1.15;

    // Thin edge response is Fresnel/thickness gated and follows reflected angles.
    float mainBox=lightBox(angular,float2(-.36,-.66)+lightShift,float2(.88,.38)*(1.0+.12*indentation),.22);
    float backBox=lightBox(angular,float2(.32,.69)-lightShift*.5,float2(.82,.22),.17);
    float edgeLight=(mainBox+backBox*.58)*smoothstep(.05,.25,length(angular));
    float edgeReflection=fresnel*edgeLight*.85*surfaceGate;
    float rim=exp(-depth/max(1.2,u.touchBezel.z*.11));
    float facing=.16+.84*pow(max(dot(surfaceNormal,normalize(float3(-.40,-.75,.55))),0.0),3.0);
    edgeReflection+=rim*fresnel*facing*1.8*surfaceGate*max(coolPanel,warmPanel);
    glass=float3(1.0)-(float3(1.0)-glass)*exp(-float3(edgeReflection));
    glass=clamp(glass,float3(0.0),float3(1.0));
    return float4(mix(background,glass,coverage),1.0);
}
