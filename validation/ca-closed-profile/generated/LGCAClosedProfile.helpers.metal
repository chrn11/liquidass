
// ---- CA closed, single-transmission material profile (new entry points) ----
// Existing Uniforms/liquidGlassPixel/liquidGlassFragment above are frozen.
// Host contract: origTex has exactly one mip level; every new sample is level 0.
// LGCA_ identifiers isolate the verified-175 formula family from baseline-149.
struct LGCA_ButtonOpticsResult {
float signedDistance;
float offsetX;
float offsetY;
float height;
float normalX;
float normalY;
float sampleU;
float sampleV;
float environmentU;
float environmentV;
float environmentWeight;
float environmentOffsetX;
float environmentOffsetY;
bool valid;
};
float LGCA_BOAbs(float x) {
return x < 0.0f ? -x : x;
}
float LGCA_BOMin(float a, float b) {
return a < b ? a : b;
}
float LGCA_BOMax(float a, float b) {
return a > b ? a : b;
}
float LGCA_BOClamp(float x, float lo, float hi) {
return LGCA_BOMin(LGCA_BOMax(x, lo), hi);
}
float LGCA_BOHypot(float x, float y) {
return sqrt(x * x + y * y);
}
float LGCA_BOSmoothCappedLength(float rawLength, float cap) {
if (!isfinite(rawLength) || !isfinite(cap) || rawLength <= 0.0f || cap <= 0.0f) return 0.0f;
float shoulder = cap * 0.25f;
float start = cap - shoulder;
if (rawLength <= start) return rawLength;
float excess = rawLength - start;
return start + shoulder * excess / (shoulder + excess);
}
float LGCA_BOButtonRoundedBoxSDF(float x, float y, float width, float height, float radius) {
float halfWidth = width * 0.5f;
float halfHeight = height * 0.5f;
float qx = LGCA_BOAbs(x) - (halfWidth - radius);
float qy = LGCA_BOAbs(y) - (halfHeight - radius);
float outsideX = LGCA_BOMax(qx, 0.0f);
float outsideY = LGCA_BOMax(qy, 0.0f);
float outside = LGCA_BOHypot(outsideX, outsideY);
float inside = LGCA_BOMin(LGCA_BOMax(qx, qy), 0.0f);
return outside + inside - radius;
}
LGCA_ButtonOpticsResult LGCA_ButtonOpticsEvaluateWithContact(float x, float y, float width, float height, float centerX, float centerY, float radius, float bezel, float glassThickness, float refractiveIndex, float refractionScale, float displacementCap, float pointScale, float rendererScale, bool enabled, bool contactEnabled, float contactX, float contactY, float contactPressure) {
LGCA_ButtonOpticsResult out;
out.signedDistance = 0.0f;
out.offsetX = 0.0f;
out.offsetY = 0.0f;
out.height = 0.0f;
out.normalX = 0.0f;
out.normalY = 0.0f;
out.sampleU = 0.0f;
out.sampleV = 0.0f;
out.environmentU = 0.0f;
out.environmentV = 0.0f;
out.environmentWeight = 0.0f;
out.environmentOffsetX = 0.0f;
out.environmentOffsetY = 0.0f;
out.valid = false;
if (!isfinite(x) || !isfinite(y) || !isfinite(width) || !isfinite(height) || !isfinite(centerX) || !isfinite(centerY) || !isfinite(radius) || !isfinite(bezel) || !isfinite(glassThickness) || !isfinite(refractiveIndex) || !isfinite(refractionScale) || !isfinite(displacementCap) || !isfinite(pointScale) || !isfinite(rendererScale)) return out;
float shortest = LGCA_BOMin(width, height);
if (width < 1.0f || height < 1.0f || width > 16384.0f || height > 16384.0f || shortest < 1.0f || centerX < 0.5f || centerX > width - 0.5f || centerY < 0.5f || centerY > height - 0.5f || radius < 0.0f || radius > shortest * 0.5f + 0.01f || bezel < 0.0f || glassThickness < 0.0f || refractiveIndex < 1.0f || refractiveIndex > 3.2f || refractionScale < 0.0f || refractionScale > 3.0f || displacementCap < 0.0f || pointScale < 0.5f || pointScale > 4.0f || rendererScale < 0.5f || rendererScale > 4.0f) return out;
float localX = x - centerX;
float localY = y - centerY;
float d = LGCA_BOButtonRoundedBoxSDF(localX, localY, width, height, radius);
if (!isfinite(d)) return out;
out.signedDistance = d;
out.valid = true;
out.sampleU = LGCA_BOClamp(x, 0.5f, width - 0.5f) / width;
out.sampleV = LGCA_BOClamp(y, 0.5f, height - 0.5f) / height;
out.environmentU = out.sampleU;
out.environmentV = out.sampleV;
if (d >= 0.0f || !enabled || glassThickness <= 0.0f || refractionScale <= 0.0f || displacementCap <= 0.0f || refractiveIndex <= 1.0f) return out;
float depth = -d;
float depthRadius = shortest * 0.5f;
float t = LGCA_BOClamp(depth / depthRadius, 0.0f, 1.0f);
float rimHeight = LGCA_BOMax(bezel, pointScale * 1.5f);
float curvatureRadius = LGCA_BOHypot(depthRadius, rimHeight);
float capSag = depthRadius * depthRadius / (curvatureRadius + rimHeight);
float surfaceRoot = sqrt(rimHeight * rimHeight + depthRadius * depthRadius * t * (2.0f - t));
float capRise = depthRadius * depthRadius * t * (2.0f - t) / (surfaceRoot + rimHeight);
float normalizedHeight = capRise / capSag;
float heightAmplitude = LGCA_BOMin(depthRadius, glassThickness) * (capSag / depthRadius);
out.height = heightAmplitude * normalizedHeight;
float lipWidth = LGCA_BOMin(pointScale * 1.5f, depthRadius);
float lipT = lipWidth / depthRadius;
float lipSurfaceRoot = sqrt(rimHeight * rimHeight + depthRadius * depthRadius * lipT * (2.0f - lipT));
float lipCapRise = depthRadius * depthRadius * lipT * (2.0f - lipT) / (lipSurfaceRoot + rimHeight);
float lipCapHeight = heightAmplitude * (lipCapRise / capSag);
float lipCapDerivative = heightAmplitude * depthRadius * (1.0f - lipT) / (lipSurfaceRoot * capSag);
float gx = LGCA_BOButtonRoundedBoxSDF(localX + 0.5f, localY, width, height, radius) - LGCA_BOButtonRoundedBoxSDF(localX - 0.5f, localY, width, height, radius);
float gy = LGCA_BOButtonRoundedBoxSDF(localX, localY + 0.5f, width, height, radius) - LGCA_BOButtonRoundedBoxSDF(localX, localY - 0.5f, width, height, radius);
float gradientLength = LGCA_BOHypot(gx, gy);
float outwardX = gradientLength > 0.0001f ? gx / gradientLength : 0.0f;
float outwardY = gradientLength > 0.0001f ? gy / gradientLength : 0.0f;
float normalizedHeightDerivative = t < 1.0f ? depthRadius * (1.0f - t) / (surfaceRoot * capSag) : 0.0f;
float heightDerivative = heightAmplitude * normalizedHeightDerivative;
float lipQ = lipCapHeight > 0.0f ? LGCA_BOClamp(lipWidth * lipCapDerivative / lipCapHeight, 0.0f, 1.0f) : 0.0f;
if (depth < lipWidth) {
float lipU = depth / lipWidth;
float lipU2 = lipU * lipU;
float lipU3 = lipU2 * lipU;
out.height = lipCapHeight * ((3.0f - lipQ) * lipU2 + (lipQ - 2.0f) * lipU3);
heightDerivative = (lipCapHeight / lipWidth) * (2.0f * (3.0f - lipQ) * lipU + 3.0f * (lipQ - 2.0f) * lipU2);
}
float normalX = heightDerivative * outwardX;
float normalY = heightDerivative * outwardY;
float normalZ = 1.0f;
bool contactInputValid = contactEnabled && isfinite(contactX) && isfinite(contactY) && isfinite(contactPressure);
if (contactInputValid && contactPressure > 0.0f) {
float boundedContactX = LGCA_BOClamp(contactX, 0.0f, 1.0f);
float boundedContactY = LGCA_BOClamp(contactY, 0.0f, 1.0f);
float boundedContactPressure = LGCA_BOClamp(contactPressure, 0.0f, 1.0f);
float contactDx = x - boundedContactX * width;
float contactDy = y - boundedContactY * height;
float contactRadius = pointScale * 7.0f;
float contactRadiusSquared = contactRadius * contactRadius;
float contactDistanceSquared = contactDx * contactDx + contactDy * contactDy;
float contactQ = contactDistanceSquared / contactRadiusSquared;
float contactDepth = -d;
float contactFadeWidth = pointScale * 1.5f;
float contactFadeT = LGCA_BOClamp(contactDepth / contactFadeWidth, 0.0f, 1.0f);
float contactEdgeFade = contactFadeT * contactFadeT * (3.0f - 2.0f * contactFadeT);
float contactEdgeFadeDerivative = (contactFadeT > 0.0f && contactFadeT < 1.0f) ? 6.0f * contactFadeT * (1.0f - contactFadeT) / contactFadeWidth : 0.0f;
if (contactQ < 1.0f && boundedContactPressure > 0.0f) {
float contactShapeBase = 1.0f - contactQ;
float contactShape = contactShapeBase * contactShapeBase * contactShapeBase;
float contactShapeGradientX = -6.0f * contactDx / contactRadiusSquared * contactShapeBase * contactShapeBase;
float contactShapeGradientY = -6.0f * contactDy / contactRadiusSquared * contactShapeBase * contactShapeBase;
float contactAmplitude = LGCA_BOMin(1.15f * pointScale, heightAmplitude * 0.20f) * boundedContactPressure;
float contactHeightDelta = -contactAmplitude * contactShape * contactEdgeFade;
float contactDepthGradientX = -outwardX;
float contactDepthGradientY = -outwardY;
float contactGradientX = -contactAmplitude * (contactShapeGradientX * contactEdgeFade + contactShape * contactEdgeFadeDerivative * contactDepthGradientX);
float contactGradientY = -contactAmplitude * (contactShapeGradientY * contactEdgeFade + contactShape * contactEdgeFadeDerivative * contactDepthGradientY);
float contactBaseHeight = LGCA_BOMax(out.height, 0.0f);
float contactRequestedDent = -contactHeightDelta;
float contactDenominator = contactBaseHeight + contactRequestedDent;
float contactHeightRatio = contactDenominator > 0.0f ? contactBaseHeight / contactDenominator : 1.0f;
float contactBaseGradientFactor = (1.0f - contactHeightRatio) * (1.0f - contactHeightRatio);
float contactDentGradientFactor = contactHeightRatio * contactHeightRatio;
contactGradientX = contactBaseGradientFactor * normalX + contactDentGradientFactor * contactGradientX;
contactGradientY = contactBaseGradientFactor * normalY + contactDentGradientFactor * contactGradientY;
if (isfinite(contactHeightRatio) && isfinite(contactGradientX) && isfinite(contactGradientY)) { out.height = contactBaseHeight * contactHeightRatio; normalX -= contactGradientX; normalY -= contactGradientY; }
}
}
float normalLength = LGCA_BOHypot(LGCA_BOHypot(normalX, normalY), normalZ);
normalX /= normalLength;
normalY /= normalLength;
normalZ /= normalLength;
out.normalX = normalX;
out.normalY = normalY;
float eta = 1.0f / refractiveIndex;
float k = LGCA_BOMax(0.0f, 1.0f - eta * eta * (1.0f - normalZ * normalZ));
float rootK = sqrt(k);
float rayFactor = eta * normalZ - rootK;
float rayX = rayFactor * normalX;
float rayY = rayFactor * normalY;
float rayZ = -eta + eta * normalZ * normalZ - rootK * normalZ;
float pathLength = LGCA_BOSmoothCappedLength(LGCA_BOMax(out.height, 0.0f), displacementCap);
float radialEdgeDepth = LGCA_BOMax(pointScale * 1.5f, depthRadius * 0.3f);
float effectiveEdgeDepth = LGCA_BOMin(LGCA_BOMax(bezel, 1.0f), radialEdgeDepth);
float edgeT = LGCA_BOClamp(depth / effectiveEdgeDepth, 0.0f, 1.0f);
float edgeFade = edgeT * edgeT * (3.0f - 2.0f * edgeT);
float denominator = LGCA_BOMax(-rayZ, 0.25f);
float offsetX = rayX / denominator * pathLength * refractionScale * edgeFade;
float offsetY = rayY / denominator * pathLength * refractionScale * edgeFade;
float offsetLength = LGCA_BOHypot(offsetX, offsetY);
if (!isfinite(offsetLength)) { out.valid = false; return out; }
float limitedOffsetLength = LGCA_BOSmoothCappedLength(offsetLength, displacementCap);
if (offsetLength > 0.0f) { float factor = limitedOffsetLength / offsetLength; offsetX *= factor; offsetY *= factor; }
out.offsetX = offsetX;
out.offsetY = offsetY;
out.sampleU = LGCA_BOClamp(x + offsetX, 0.5f, width - 0.5f) / width;
out.sampleV = LGCA_BOClamp(y + offsetY, 0.5f, height - 0.5f) / height;
out.environmentWeight = 0.0f;
out.environmentOffsetX = out.offsetX;
out.environmentOffsetY = out.offsetY;
out.environmentU = out.sampleU;
out.environmentV = out.sampleV;
return out;
}
LGCA_ButtonOpticsResult LGCA_ButtonOpticsEvaluate(float x, float y, float width, float height, float centerX, float centerY, float radius, float bezel, float glassThickness, float refractiveIndex, float refractionScale, float displacementCap, float pointScale, float rendererScale, bool enabled) {
return LGCA_ButtonOpticsEvaluateWithContact(x, y, width, height, centerX, centerY, radius, bezel, glassThickness, refractiveIndex, refractionScale, displacementCap, pointScale, rendererScale, enabled, false, 0.0f, 0.0f, 0.0f);
}
float LGCA_BOImageEdgeRadianceWeight(LGCA_ButtonOpticsResult q, float width, float height, float bezel, float pointScale, float refractiveIndex, bool enabled, bool leasedOverscan) {
if (!q.valid || !enabled || !leasedOverscan || !isfinite(width) || !isfinite(height) || !isfinite(bezel) || !isfinite(pointScale) || !isfinite(refractiveIndex) || !isfinite(q.signedDistance) || !isfinite(q.height) || !isfinite(q.normalX) || !isfinite(q.normalY) || q.signedDistance >= 0.0f || q.height <= 0.0f || width < 1.0f || width > 16384.0f || height < 1.0f || height > 16384.0f || pointScale < 0.5f || pointScale > 4.0f || refractiveIndex <= 1.0f || refractiveIndex > 3.2f) return 0.0f;
float shortest = LGCA_BOMin(width, height);
float lipWidth = LGCA_BOMin(pointScale * 1.5f, shortest * 0.5f);
if (lipWidth <= 0.0f) return 0.0f;
float edgeT = LGCA_BOClamp(-q.signedDistance / lipWidth, 0.0f, 1.0f);
float edgeBand = 1.0f - edgeT * edgeT * (3.0f - 2.0f * edgeT);
float normalXY2 = LGCA_BOClamp(q.normalX * q.normalX + q.normalY * q.normalY, 0.0f, 1.0f);
float cosineIncident = sqrt(LGCA_BOClamp(1.0f - normalXY2, 0.0f, 1.0f));
float ratio = (refractiveIndex - 1.0f) / (refractiveIndex + 1.0f);
float f0 = ratio * ratio;
float oneMinusCosine = 1.0f - cosineIncident;
float oneMinusCosine2 = oneMinusCosine * oneMinusCosine;
float schlick = f0 + (1.0f - f0) * oneMinusCosine2 * oneMinusCosine2 * oneMinusCosine;
float thicknessT = LGCA_BOClamp(q.height / lipWidth, 0.0f, 1.0f);
float thicknessCoverage = thicknessT * thicknessT * (3.0f - 2.0f * thicknessT);
float weight = edgeBand * schlick * thicknessCoverage;
if (!isfinite(weight)) return 0.0f;
return LGCA_BOClamp(weight, 0.0f, 0.28f);
}
float LGCA_BOImageEdgeRadianceRadius(float localHeight, float pointScale) {
if (!isfinite(localHeight) || !isfinite(pointScale) || pointScale <= 0.0f) return 0.0f;
float screenConeTangent = 0.21255656f;
float requestedRadius = LGCA_BOMax(localHeight, 0.0f) * screenConeTangent;
float legalRadius = 16.0f * pointScale;
return LGCA_BOSmoothCappedLength(requestedRadius, legalRadius);
}
float LGCA_BOAverageFourRadianceSamples(float a, float b, float c, float d) {
return 0.25f * (a + b + c + d);
}
float LGCA_BOEnvironmentMixPremultipliedChannel(float transmittedPremul, float transmittedAlpha, float environmentPremul, float environmentAlpha, float weight) {
float alpha = LGCA_BOClamp(transmittedAlpha, 0.0f, 1.0f);
if (alpha <= 0.00001f) return 0.0f;
float transmittedStraight = LGCA_BOClamp(transmittedPremul / alpha, 0.0f, 1.0f);
float pathAlpha = LGCA_BOClamp(environmentAlpha, 0.0f, 1.0f);
float pathStraight = pathAlpha > 0.00001f ? LGCA_BOClamp(environmentPremul / pathAlpha, 0.0f, 1.0f) : transmittedStraight;
float boundedWeight = LGCA_BOClamp(weight, 0.0f, 0.28f);
float straightResult = transmittedStraight + (pathStraight - transmittedStraight) * boundedWeight;
return LGCA_BOClamp(straightResult, 0.0f, 1.0f) * alpha;
}
struct LGCA_MinificationFootprint {
float major;
float minor;
float filterWidth;
float kernelXX;
float kernelXY;
float kernelYY;
int tapCount;
bool valid;
};
float LGCA_BOMinificationExcess(float singularValue) {
float q=LGCA_BOClamp((singularValue-1.0f)*4.0f,0.0f,1.0f);
float activation=q*q*(3.0f-2.0f*q);
float support=LGCA_BOClamp(singularValue,1.0f,4.0f);
return (support*support-1.0f)*activation*activation;
}
LGCA_MinificationFootprint LGCA_BOAnalyzeMinificationFootprint(float dxX, float dxY, float dyX, float dyY) {
LGCA_MinificationFootprint out;
out.major=1.0f; out.minor=1.0f; out.filterWidth=1.0f;
out.kernelXX=0.0f; out.kernelXY=0.0f; out.kernelYY=0.0f;
out.tapCount=1; out.valid=false;
if (!isfinite(dxX)||!isfinite(dxY)||!isfinite(dyX)||!isfinite(dyY)) return out;
float c00=dxX*dxX+dyX*dyX;
float c01=dxX*dxY+dyX*dyY;
float c11=dxY*dxY+dyY*dyY;
float trace=c00+c11;
if (!isfinite(c00)||!isfinite(c01)||!isfinite(c11)||!isfinite(trace)) return out;
float delta=c00-c11;
float discScale=LGCA_BOMax(fabs(delta),2.0f*fabs(c01));
float discriminant=0.0f;
if (discScale>0.0f) { float a=delta/discScale; float b=2.0f*c01/discScale; discriminant=discScale*sqrt(a*a+b*b); }
float lambdaMajor=LGCA_BOMax(0.0f,0.5f*(trace+discriminant));
float lambdaMinor=LGCA_BOClamp(0.5f*(trace-discriminant),0.0f,lambdaMajor);
float major=sqrt(lambdaMajor); float minor=sqrt(lambdaMinor);
if (!isfinite(major)||!isfinite(minor)) return out;
out.major=major; out.minor=minor; out.filterWidth=LGCA_BOClamp(major,1.0f,4.0f); out.valid=true;
if (major<=1.0f) return out;
float eMajor=LGCA_BOMinificationExcess(major); float eMinor=LGCA_BOMinificationExcess(minor);
float spectralSlope=(eMajor-eMinor)/LGCA_BOMax(discriminant,1.0e-20f);
float e00=LGCA_BOMax(0.0f,eMinor+spectralSlope*(c00-lambdaMinor));
float e01=spectralSlope*c01;
float e11=LGCA_BOMax(0.0f,eMinor+spectralSlope*(c11-lambdaMinor));
float rootDet=sqrt(LGCA_BOMax(0.0f,e00*e11-e01*e01));
float divisor=sqrt(LGCA_BOMax(0.0f,e00+e11+2.0f*rootDet));
if (!isfinite(divisor)||divisor<=1.0e-12f) return out;
float gain=0.12909944487358055f/divisor;
out.kernelXX=(e00+rootDet)*gain;
out.kernelXY=e01*gain;
out.kernelYY=(e11+rootDet)*gain;
out.tapCount=4;
return out;
}
float LGCA_DesignedDielectricFresnel(float ci, float index) {
if (!isfinite(ci) || !isfinite(index) || index<=1.0f || index>3.2f) return 0.0f;
ci=LGCA_BOClamp(ci,0.0f,1.0f);
float ct=sqrt(LGCA_BOMax(0.0f,1.0f-(1.0f-ci*ci)/(index*index)));
float rs=(ci-index*ct)/(ci+index*ct);
float rp=(index*ci-ct)/(index*ci+ct);
return LGCA_BOClamp(0.5f*(rs*rs+rp*rp),0.0f,1.0f);
}
float LGCA_DesignedSoftboxCoefficient(LGCA_ButtonOpticsResult q, float index, float pointScale, float explicitStrength) {
if (!isfinite(explicitStrength) || explicitStrength<=0.0f || !q.valid || !isfinite(q.height) || q.height<=0.0f || !isfinite(q.signedDistance) || q.signedDistance>=0.0f || !isfinite(q.normalX) || !isfinite(q.normalY) || !isfinite(pointScale) || pointScale<0.5f || pointScale>4.0f || !isfinite(index) || index<=1.0f || index>3.2f) return 0.0f;
float nz=sqrt(LGCA_BOClamp(1.0f-q.normalX*q.normalX-q.normalY*q.normalY,0.0f,1.0f));
float reflectedX=2.0f*nz*q.normalX;
float reflectedY=2.0f*nz*q.normalY;
float reflectedZ=2.0f*nz*nz-1.0f;
float cosineAperture=-0.6644630244f*reflectedX-0.6644630244f*reflectedY-0.3420201433f*reflectedZ;
float apertureT=LGCA_BOClamp((cosineAperture-0.8829475929f)/(0.9702957263f-0.8829475929f),0.0f,1.0f);
float aperture=apertureT*apertureT*(3.0f-2.0f*apertureT);
float heightT=LGCA_BOClamp(q.height/(1.5f*pointScale),0.0f,1.0f);
float heightCoverage=heightT*heightT*(3.0f-2.0f*heightT);
float coefficient=LGCA_DesignedDielectricFresnel(nz,index)*aperture*heightCoverage*LGCA_BOClamp(explicitStrength,0.0f,1.0f);
return isfinite(coefficient)?LGCA_BOClamp(coefficient,0.0f,1.0f):0.0f;
}
float LGCA_DesignedSoftboxPremultipliedChannel(float basePremul, float alpha, float coefficient) {
if (!isfinite(coefficient) || coefficient<=0.0f || !isfinite(alpha) || alpha<=0.0f) return basePremul;
float w=LGCA_BOClamp(coefficient,0.0f,1.0f);
return basePremul+(alpha-basePremul)*w;
}


float2 LGCA_SourceTexels(LGCA_ButtonOpticsResult q,
                         texture2d<float, access::sample> source) {
    return float2(q.sampleU,q.sampleV) *
           float2((float)source.get_width(),(float)source.get_height());
}

LGCA_ButtonOpticsResult LGCA_EvaluateAt(float2 point, constant Uniforms &u) {
    return LGCA_ButtonOpticsEvaluateWithContact(
        point.x,point.y,u.resolution.x,u.resolution.y,
        u.buttonCandidateCenter.x,u.buttonCandidateCenter.y,
        u.buttonCandidateCornerRadius,u.bezelWidth,
        u.glassThickness,u.refractiveIndex,u.refractionScale,
        u.buttonCandidateMaxOffset,u.buttonCandidatePointScale,
        u.buttonCandidateRendererScale,true,false,0.5f,0.5f,0.0f);
}

float4 LGCA_MinifiedSample(texture2d<float, access::sample> source,
                           sampler s, float2 sourceUV,
                           LGCA_MinificationFootprint footprint) {
    float2 dimensions=float2((float)source.get_width(),(float)source.get_height());
    float2 halfTexel=0.5f/dimensions;
    float2 highUV=1.0f-halfTexel;
    if (footprint.tapCount!=4)
        return source.sample(s,sourceUV,level(0.0f));
    float2 deltaA=float2(3.0f*footprint.kernelXX+footprint.kernelXY,
                         3.0f*footprint.kernelXY+footprint.kernelYY)/dimensions;
    float2 deltaB=float2(footprint.kernelXX-3.0f*footprint.kernelXY,
                         footprint.kernelXY-3.0f*footprint.kernelYY)/dimensions;
    float2 a=clamp(sourceUV-deltaA,halfTexel,highUV);
    float2 b=clamp(sourceUV-deltaB,halfTexel,highUV);
    float2 c=clamp(sourceUV+deltaB,halfTexel,highUV);
    float2 e=clamp(sourceUV+deltaA,halfTexel,highUV);
    return 0.25f*(source.sample(s,a,level(0.0f))+
                  source.sample(s,b,level(0.0f))+
                  source.sample(s,c,level(0.0f))+
                  source.sample(s,e,level(0.0f)));
}


float4 LGCA_DesignedLighting(float4 base, LGCA_ButtonOpticsResult q,
                             LGCA_ButtonOpticsResult mx, LGCA_ButtonOpticsResult px,
                             LGCA_ButtonOpticsResult my, LGCA_ButtonOpticsResult py,
                             constant Uniforms &u) {
    if (!isfinite(u.fresnelGlareStrength) || u.fresnelGlareStrength<=0.0f)
        return base;
    float w=0.5f*LGCA_DesignedSoftboxCoefficient(
        q,u.refractiveIndex,u.buttonCandidatePointScale,u.fresnelGlareStrength);
    w+=0.125f*LGCA_DesignedSoftboxCoefficient(
        mx,u.refractiveIndex,u.buttonCandidatePointScale,u.fresnelGlareStrength);
    w+=0.125f*LGCA_DesignedSoftboxCoefficient(
        px,u.refractiveIndex,u.buttonCandidatePointScale,u.fresnelGlareStrength);
    w+=0.125f*LGCA_DesignedSoftboxCoefficient(
        my,u.refractiveIndex,u.buttonCandidatePointScale,u.fresnelGlareStrength);
    w+=0.125f*LGCA_DesignedSoftboxCoefficient(
        py,u.refractiveIndex,u.buttonCandidatePointScale,u.fresnelGlareStrength);
    return float4(LGCA_DesignedSoftboxPremultipliedChannel(base.r,base.a,w),
                  LGCA_DesignedSoftboxPremultipliedChannel(base.g,base.a,w),
                  LGCA_DesignedSoftboxPremultipliedChannel(base.b,base.a,w),base.a);
}


bool LGCA_ClosedUniformsAreLegal(constant Uniforms &u, uint2 dimensions) {
    float shortest=min(u.resolution.x,u.resolution.y);
    return dimensions.x>0 && dimensions.y>0 &&
        isfinite(u.resolution.x) && isfinite(u.resolution.y) &&
        u.resolution.x>=1.0f && u.resolution.y>=1.0f &&
        isfinite(u.outputResolution.x) && isfinite(u.outputResolution.y) &&
        u.outputResolution.x>=1.0f && u.outputResolution.y>=1.0f &&
        u.useGlyphMask==0.0f && isfinite(u.shapeScale) &&
        u.shapeScale>=0.999f && u.shapeScale<=1.0f &&
        isfinite(u.shapeOrigin.x) && isfinite(u.shapeOrigin.y) &&
        isfinite(u.shapeSize.x) && isfinite(u.shapeSize.y) &&
        u.shapeSize.x>=0.0f && u.shapeSize.y>=0.0f &&
        u.shapeSize.x<=0.5f && u.shapeSize.y<=0.5f &&
        isfinite(u.radius) && isfinite(u.bezelWidth) &&
        isfinite(u.glassThickness) && isfinite(u.refractionScale) &&
        isfinite(u.refractiveIndex) &&
        isfinite(u.buttonCandidateCenter.x) && isfinite(u.buttonCandidateCenter.y) &&
        isfinite(u.buttonCandidateCornerRadius) &&
        isfinite(u.buttonCandidateMaxOffset) &&
        isfinite(u.buttonCandidatePointScale) &&
        isfinite(u.buttonCandidateRendererScale) &&
        isfinite(u.fresnelGlareStrength) &&
        u.buttonCandidateCenter.x>=0.5f &&
        u.buttonCandidateCenter.x<=u.resolution.x-0.5f &&
        u.buttonCandidateCenter.y>=0.5f &&
        u.buttonCandidateCenter.y<=u.resolution.y-0.5f &&
        u.buttonCandidateCornerRadius>=0.0f &&
        u.buttonCandidateCornerRadius<=shortest*0.5f+0.01f &&
        u.radius==u.buttonCandidateCornerRadius &&
        u.bezelWidth>=0.0f && u.glassThickness>=0.0f &&
        u.refractionScale>=0.0f && u.refractionScale<=3.0f &&
        u.refractiveIndex>=1.0f && u.refractiveIndex<=3.2f &&
        u.buttonCandidateMaxOffset>0.0f &&
        u.buttonCandidatePointScale>=0.5f && u.buttonCandidatePointScale<=4.0f &&
        u.buttonCandidateRendererScale>=0.5f && u.buttonCandidateRendererScale<=4.0f &&
        (u.fresnelGlareStrength==0.0f || u.fresnelGlareStrength==1.0f);
}

float4 LGCA_ClosedProfilePixel(texture2d<float, access::sample> src,
                               texture2d<float, access::sample> glyphMask,
                               constant Uniforms &u, uint2 gid, uint2 dimensions) {
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    float2 captureUV=(float2(gid)+0.5f)/float2(dimensions);
    float2 point=captureUV*u.resolution;
    LGCA_ButtonOpticsResult q=LGCA_EvaluateAt(point,u);
    if (!q.valid) return liquidGlassPixel(src,glyphMask,u,gid,dimensions);
    if (q.signedDistance>=0.0f)
        return src.sample(s,captureUV,level(0.0f));

    // Exact +/-0.5-pixel geometry differences feed the verified PSD footprint.
    LGCA_ButtonOpticsResult mx=LGCA_EvaluateAt(point+float2(-0.5f,0.0f),u);
    LGCA_ButtonOpticsResult px=LGCA_EvaluateAt(point+float2( 0.5f,0.0f),u);
    LGCA_ButtonOpticsResult my=LGCA_EvaluateAt(point+float2(0.0f,-0.5f),u);
    LGCA_ButtonOpticsResult py=LGCA_EvaluateAt(point+float2(0.0f, 0.5f),u);
    if (!mx.valid || !px.valid || !my.valid || !py.valid)
        return liquidGlassPixel(src,glyphMask,u,gid,dimensions);

    float2 sxm=LGCA_SourceTexels(mx,src);
    float2 sxp=LGCA_SourceTexels(px,src);
    float2 sym=LGCA_SourceTexels(my,src);
    float2 syp=LGCA_SourceTexels(py,src);
    LGCA_MinificationFootprint footprint=LGCA_BOAnalyzeMinificationFootprint(
        sxp.x-sxm.x,sxp.y-sxm.y,syp.x-sym.x,syp.y-sym.y);
    // No overscan, padding, environment path or second transmission image.
    float4 transmitted=LGCA_MinifiedSample(
        src,s,float2(q.sampleU,q.sampleV),footprint);
    return LGCA_DesignedLighting(transmitted,q,mx,px,my,py,u);
}

fragment float4 liquidGlassCAClosedFragment(
    LGVertexOut in [[stage_in]],
    texture2d<float, access::sample> src [[texture(0)]],
    texture2d<float, access::sample> glyphMask [[texture(1)]],
    constant Uniforms &u [[buffer(0)]],
    device atomic_uint *auditWord [[buffer(1)]]) {
    uint2 dimensions(src.get_width(), src.get_height());
    float2 sourcePosition =
        in.position.xy - (u.outputResolution - u.resolution) * 0.5;
    if (any(sourcePosition < float2(0.0)) ||
        any(sourcePosition >= u.resolution)) return float4(0.0);
    uint2 gid = min(uint2(sourcePosition), dimensions - 1);
    if (atomic_load_explicit(auditWord,memory_order_relaxed)!=0x4c474341u ||
        u.buttonCandidate!=2.0f ||
        !LGCA_ClosedUniformsAreLegal(u,dimensions))
        return liquidGlassPixel(src,glyphMask,u,gid,dimensions);
    return LGCA_ClosedProfilePixel(src,glyphMask,u,gid,dimensions);
}

kernel void LGCAAuditOpaque(
    texture2d<float, access::read> src [[texture(0)]],
    device atomic_uint *auditWord [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x>=src.get_width() || gid.y>=src.get_height()) return;
    float alpha=src.read(gid).a;
    atomic_fetch_add_explicit(auditWord,1u,memory_order_relaxed);
    if (!isfinite(alpha) || alpha!=1.0f)
        atomic_fetch_or_explicit(auditWord,0x80000000u,memory_order_relaxed);
}

kernel void LGCAFinalizeOpaque(
    texture2d<float, access::read> src [[texture(0)]],
    device atomic_uint *auditWord [[buffer(1)]],
    uint tid [[thread_position_in_grid]]) {
    if (tid!=0u) return;
    uint expected=src.get_width()*src.get_height();
    uint observed=atomic_load_explicit(auditWord,memory_order_relaxed);
    bool noBadBit=(observed&0x80000000u)==0u;
    if (noBadBit && observed==expected)
        atomic_store_explicit(auditWord,0x4c474341u,memory_order_relaxed);
    else
        atomic_store_explicit(auditWord,0u,memory_order_relaxed);
}
