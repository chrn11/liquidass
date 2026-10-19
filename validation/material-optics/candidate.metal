#define LG_BUTTON_OPTICS_COMPILED 1

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 resolution;
    float2 outputResolution;
    float2 screenResolution;
    float2 cardOrigin;
    float2 wallpaperResolution;
    float2 lensOrigin;
    float  radius;
    float  bezelWidth;
    float  glassThickness;
    float  refractionScale;
    float  refractiveIndex;
    float2 wallpaperOrigin;
    float2 samplingTransformX;
    float2 samplingTransformY;
    float2 samplingTransformOffset;
    float  samplingOrientation;
    float  backdropZoom;
    float  shapeScale;
    float2 shapeOrigin;
    float2 shapeSize;
    float  useGlyphMask;
    float  dispersionStrength;
    float  fresnelGlareStrength;
    float  borderWidthPixels;
    float4 tintColor;
    float buttonCandidate;
    float buttonCandidateMaxOffset;
    float2 buttonCandidateCenter;
    float buttonCandidatePointScale;
    float buttonCandidateCornerRadius;
    float buttonCandidateRendererScale;
    float2 buttonContactCenter;
    float buttonContactPressure;
    float buttonContactEnabled;
    float2 buttonSourceTargetOriginPixels;
    float buttonSourceOverscanEnabled;
};

#if LG_BUTTON_OPTICS_COMPILED
struct LGButtonOpticsResult {
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
float LGBOAbs(float x) {
return x < 0.0f ? -x : x;
}
float LGBOMin(float a, float b) {
return a < b ? a : b;
}
float LGBOMax(float a, float b) {
return a > b ? a : b;
}
float LGBOClamp(float x, float lo, float hi) {
return LGBOMin(LGBOMax(x, lo), hi);
}
float LGBOHypot(float x, float y) {
return sqrt(x * x + y * y);
}
float LGBOSmoothCappedLength(float rawLength, float cap) {
if (!isfinite(rawLength) || !isfinite(cap) || rawLength <= 0.0f || cap <= 0.0f) return 0.0f;
float shoulder = cap * 0.25f;
float start = cap - shoulder;
if (rawLength <= start) return rawLength;
float excess = rawLength - start;
return start + shoulder * excess / (shoulder + excess);
}
float LGBOButtonRoundedBoxSDF(float x, float y, float width, float height, float radius) {
float halfWidth = width * 0.5f;
float halfHeight = height * 0.5f;
float qx = LGBOAbs(x) - (halfWidth - radius);
float qy = LGBOAbs(y) - (halfHeight - radius);
float outsideX = LGBOMax(qx, 0.0f);
float outsideY = LGBOMax(qy, 0.0f);
float outside = LGBOHypot(outsideX, outsideY);
float inside = LGBOMin(LGBOMax(qx, qy), 0.0f);
return outside + inside - radius;
}
LGButtonOpticsResult LGButtonOpticsEvaluateWithContact(float x, float y, float width, float height, float centerX, float centerY, float radius, float bezel, float glassThickness, float refractiveIndex, float refractionScale, float displacementCap, float pointScale, float rendererScale, bool enabled, bool contactEnabled, float contactX, float contactY, float contactPressure) {
LGButtonOpticsResult out;
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
float shortest = LGBOMin(width, height);
if (width < 1.0f || height < 1.0f || width > 16384.0f || height > 16384.0f || shortest < 1.0f || centerX < 0.5f || centerX > width - 0.5f || centerY < 0.5f || centerY > height - 0.5f || radius < 0.0f || radius > shortest * 0.5f + 0.01f || bezel < 0.0f || glassThickness < 0.0f || refractiveIndex < 1.0f || refractiveIndex > 3.2f || refractionScale < 0.0f || refractionScale > 3.0f || displacementCap < 0.0f || pointScale < 0.5f || pointScale > 4.0f || rendererScale < 0.5f || rendererScale > 4.0f) return out;
float localX = x - centerX;
float localY = y - centerY;
float d = LGBOButtonRoundedBoxSDF(localX, localY, width, height, radius);
if (!isfinite(d)) return out;
out.signedDistance = d;
out.valid = true;
out.sampleU = LGBOClamp(x, 0.5f, width - 0.5f) / width;
out.sampleV = LGBOClamp(y, 0.5f, height - 0.5f) / height;
out.environmentU = out.sampleU;
out.environmentV = out.sampleV;
if (d >= 0.0f || !enabled || glassThickness <= 0.0f || refractionScale <= 0.0f || displacementCap <= 0.0f || refractiveIndex <= 1.0f) return out;
float halfWidth = width * 0.5f;
float halfHeight = height * 0.5f;
float depth = -d;
float depthRadius = shortest * 0.5f;
float t = LGBOClamp(depth / depthRadius, 0.0f, 1.0f);
float depthCurve = t * (2.0f - t);
float nx = localX / halfWidth;
float ny = localY / halfHeight;
float axial = LGBOClamp(1.0f - 0.20f * (nx * nx + ny * ny), 0.0f, 1.0f);
float q = LGBOClamp(depthCurve * axial, 0.0f, 1.0f);
float regularizer = 0.03125f;
float normalization = sqrt(1.0f + regularizer * regularizer) - regularizer;
float root = sqrt(q + regularizer * regularizer);
float normalizedHeight = (root - regularizer) / normalization;
float heightAmplitude = LGBOMin(depthRadius, glassThickness);
out.height = heightAmplitude * normalizedHeight;
float gx = LGBOButtonRoundedBoxSDF(localX + 0.5f, localY, width, height, radius) - LGBOButtonRoundedBoxSDF(localX - 0.5f, localY, width, height, radius);
float gy = LGBOButtonRoundedBoxSDF(localX, localY + 0.5f, width, height, radius) - LGBOButtonRoundedBoxSDF(localX, localY - 0.5f, width, height, radius);
float gradientLength = LGBOHypot(gx, gy);
float outwardX = gradientLength > 0.0001f ? gx / gradientLength : 0.0f;
float outwardY = gradientLength > 0.0001f ? gy / gradientLength : 0.0f;
float depthCurveDerivative = t < 1.0f ? 2.0f * (1.0f - t) / depthRadius : 0.0f;
float depthGradientX = -outwardX;
float depthGradientY = -outwardY;
float axialGradientX = -0.40f * nx / halfWidth;
float axialGradientY = -0.40f * ny / halfHeight;
float qGradientX = axial * depthCurveDerivative * depthGradientX + depthCurve * axialGradientX;
float qGradientY = axial * depthCurveDerivative * depthGradientY + depthCurve * axialGradientY;
float heightDerivative = heightAmplitude / (2.0f * root * normalization);
float normalX = -heightDerivative * qGradientX;
float normalY = -heightDerivative * qGradientY;
float normalZ = 1.0f;
bool contactInputValid = contactEnabled && isfinite(contactX) && isfinite(contactY) && isfinite(contactPressure);
if (contactInputValid && contactPressure > 0.0f) {
float boundedContactX = LGBOClamp(contactX, 0.0f, 1.0f);
float boundedContactY = LGBOClamp(contactY, 0.0f, 1.0f);
float boundedContactPressure = LGBOClamp(contactPressure, 0.0f, 1.0f);
float contactDx = x - boundedContactX * width;
float contactDy = y - boundedContactY * height;
float contactRadius = pointScale * 7.0f;
float contactRadiusSquared = contactRadius * contactRadius;
float contactDistanceSquared = contactDx * contactDx + contactDy * contactDy;
float contactQ = contactDistanceSquared / contactRadiusSquared;
float contactDepth = -d;
float contactFadeWidth = pointScale * 1.5f;
float contactFadeT = LGBOClamp(contactDepth / contactFadeWidth, 0.0f, 1.0f);
float contactEdgeFade = contactFadeT * contactFadeT * (3.0f - 2.0f * contactFadeT);
float contactEdgeFadeDerivative = (contactFadeT > 0.0f && contactFadeT < 1.0f) ? 6.0f * contactFadeT * (1.0f - contactFadeT) / contactFadeWidth : 0.0f;
if (contactQ < 1.0f && boundedContactPressure > 0.0f) {
float contactShapeBase = 1.0f - contactQ;
float contactShape = contactShapeBase * contactShapeBase * contactShapeBase;
float contactShapeGradientX = -6.0f * contactDx / contactRadiusSquared * contactShapeBase * contactShapeBase;
float contactShapeGradientY = -6.0f * contactDy / contactRadiusSquared * contactShapeBase * contactShapeBase;
float contactAmplitude = LGBOMin(1.15f * pointScale, heightAmplitude * 0.20f) * boundedContactPressure;
float contactHeightDelta = -contactAmplitude * contactShape * contactEdgeFade;
float contactDepthGradientX = -outwardX;
float contactDepthGradientY = -outwardY;
float contactGradientX = -contactAmplitude * (contactShapeGradientX * contactEdgeFade + contactShape * contactEdgeFadeDerivative * contactDepthGradientX);
float contactGradientY = -contactAmplitude * (contactShapeGradientY * contactEdgeFade + contactShape * contactEdgeFadeDerivative * contactDepthGradientY);
if (isfinite(contactHeightDelta) && isfinite(contactGradientX) && isfinite(contactGradientY)) { out.height += contactHeightDelta; normalX -= contactGradientX; normalY -= contactGradientY; }
}
}
float normalLength = LGBOHypot(LGBOHypot(normalX, normalY), normalZ);
normalX /= normalLength;
normalY /= normalLength;
normalZ /= normalLength;
out.normalX = normalX;
out.normalY = normalY;
float eta = 1.0f / refractiveIndex;
float k = LGBOMax(0.0f, 1.0f - eta * eta * (1.0f - normalZ * normalZ));
float rootK = sqrt(k);
float rayFactor = eta * normalZ - rootK;
float rayX = rayFactor * normalX;
float rayY = rayFactor * normalY;
float rayZ = -eta + eta * normalZ * normalZ - rootK * normalZ;
float pathLength = LGBOMin(displacementCap, heightAmplitude);
float radialEdgeDepth = LGBOMax(pointScale * 1.5f, depthRadius * 0.3f);
float effectiveEdgeDepth = LGBOMin(LGBOMax(bezel, 1.0f), radialEdgeDepth);
float edgeT = LGBOClamp(depth / effectiveEdgeDepth, 0.0f, 1.0f);
float edgeFade = edgeT * edgeT * (3.0f - 2.0f * edgeT);
float denominator = LGBOMax(-rayZ, 0.25f);
float offsetX = rayX / denominator * pathLength * refractionScale * edgeFade;
float offsetY = rayY / denominator * pathLength * refractionScale * edgeFade;
float offsetLength = LGBOHypot(offsetX, offsetY);
if (!isfinite(offsetLength)) { out.valid = false; return out; }
float limitedOffsetLength = LGBOSmoothCappedLength(offsetLength, displacementCap);
if (offsetLength > 0.0f) { float factor = limitedOffsetLength / offsetLength; offsetX *= factor; offsetY *= factor; }
out.offsetX = offsetX;
out.offsetY = offsetY;
out.sampleU = LGBOClamp(x + offsetX, 0.5f, width - 0.5f) / width;
out.sampleV = LGBOClamp(y + offsetY, 0.5f, height - 0.5f) / height;
float normalCosine = LGBOClamp(normalZ, 0.0f, 1.0f);
float fresnelBaseRatio = (refractiveIndex - 1.0f) / (refractiveIndex + 1.0f);
float fresnelBase = fresnelBaseRatio * fresnelBaseRatio;
float fresnelEdge = fresnelBase + (1.0f - fresnelBase) * pow(1.0f - normalCosine, 5.0f);
float thicknessCoverage = LGBOClamp(glassThickness / LGBOMax(bezel, 1.0f), 0.0f, 1.0f);
float environmentEdgeCoverage = edgeFade;
out.environmentWeight = LGBOMin(fresnelEdge * environmentEdgeCoverage * thicknessCoverage, 0.28f);
float thicknessPathFraction = 0.35f + 0.65f * edgeFade;
float environmentPath = LGBOMin(glassThickness, LGBOMax(bezel, 1.0f)) * 0.38f * refractionScale * thicknessPathFraction;
float environmentOffsetX = rayX / denominator * environmentPath;
float environmentOffsetY = rayY / denominator * environmentPath;
float environmentLength = LGBOHypot(environmentOffsetX, environmentOffsetY);
float environmentCap = LGBOMin(displacementCap * 0.45f, LGBOMin(glassThickness, LGBOMax(bezel, 1.0f)) * 0.38f);
if (!isfinite(environmentLength) || !isfinite(out.environmentWeight)) { out.valid = false; return out; }
float limitedEnvironmentLength = LGBOSmoothCappedLength(environmentLength, environmentCap);
if (environmentLength > 0.0f) { float factor = limitedEnvironmentLength / environmentLength; environmentOffsetX *= factor; environmentOffsetY *= factor; }
out.environmentOffsetX = environmentOffsetX;
out.environmentOffsetY = environmentOffsetY;
out.environmentU = LGBOClamp(x + environmentOffsetX, 0.5f, width - 0.5f) / width;
out.environmentV = LGBOClamp(y + environmentOffsetY, 0.5f, height - 0.5f) / height;
return out;
}
LGButtonOpticsResult LGButtonOpticsEvaluate(float x, float y, float width, float height, float centerX, float centerY, float radius, float bezel, float glassThickness, float refractiveIndex, float refractionScale, float displacementCap, float pointScale, float rendererScale, bool enabled) {
return LGButtonOpticsEvaluateWithContact(x, y, width, height, centerX, centerY, radius, bezel, glassThickness, refractiveIndex, refractionScale, displacementCap, pointScale, rendererScale, enabled, false, 0.0f, 0.0f, 0.0f);
}
float LGBOEnvironmentMixPremultipliedChannel(float transmittedPremul, float transmittedAlpha, float environmentPremul, float environmentAlpha, float weight) {
float alpha = LGBOClamp(transmittedAlpha, 0.0f, 1.0f);
if (alpha <= 0.00001f) return 0.0f;
float transmittedStraight = LGBOClamp(transmittedPremul / alpha, 0.0f, 1.0f);
float pathAlpha = LGBOClamp(environmentAlpha, 0.0f, 1.0f);
float pathStraight = pathAlpha > 0.00001f ? LGBOClamp(environmentPremul / pathAlpha, 0.0f, 1.0f) : transmittedStraight;
float boundedWeight = LGBOClamp(weight, 0.0f, 0.28f);
float straightResult = transmittedStraight + (pathStraight - transmittedStraight) * boundedWeight;
return LGBOClamp(straightResult, 0.0f, 1.0f) * alpha;
}
float LGBOMapTargetUVToSource(float targetUV, float targetPixels, float sourcePixels, float originPixels, bool overscanEnabled) {
if (!overscanEnabled) return targetUV;
if (!isfinite(targetUV) || !isfinite(targetPixels) || !isfinite(sourcePixels) || !isfinite(originPixels) || targetPixels < 1.0f || sourcePixels < targetPixels || sourcePixels > 16384.0f || originPixels < 0.0f || originPixels + targetPixels > sourcePixels + 0.001f) return 0.0f;
float sourcePixel = originPixels + targetUV * targetPixels;
if (!isfinite(sourcePixel)) return 0.0f;
return LGBOClamp(sourcePixel, 0.5f, sourcePixels - 0.5f) / sourcePixels;
}
struct LGMinificationFootprint {
float axisX;
float axisY;
float major;
float minor;
float filterWidth;
int tapCount;
bool valid;
};
LGMinificationFootprint LGBOAnalyzeMinificationFootprint(float dxX, float dxY, float dyX, float dyY) {
LGMinificationFootprint out;
out.axisX = 1.0f;
out.axisY = 0.0f;
out.major = 1.0f;
out.minor = 1.0f;
out.filterWidth = 1.0f;
out.tapCount = 1;
out.valid = false;
if (!isfinite(dxX) || !isfinite(dxY) || !isfinite(dyX) || !isfinite(dyY)) return out;
float c00 = dxX * dxX + dyX * dyX;
float c01 = dxX * dxY + dyX * dyY;
float c11 = dxY * dxY + dyY * dyY;
float trace = c00 + c11;
float discriminant = sqrt(LGBOClamp((c00 - c11) * (c00 - c11) + 4.0f * c01 * c01, 0.0f, 3.0e38f));
float lambdaMajor = LGBOClamp(0.5f * (trace + discriminant), 0.0f, 3.0e38f);
float lambdaMinor = LGBOClamp(0.5f * (trace - discriminant), 0.0f, lambdaMajor);
float major = sqrt(lambdaMajor);
float minor = sqrt(lambdaMinor);
if (!isfinite(major) || !isfinite(minor)) return out;
out.major = major;
out.minor = minor;
out.valid = true;
if (major <= 1.001f) return out;
float axisX = 1.0f;
float axisY = 0.0f;
if (c00 >= c11 && fabs(c01) <= 0.000001f) { axisX = 1.0f; axisY = 0.0f; }
else if (fabs(c01) <= 0.000001f) { axisX = 0.0f; axisY = 1.0f; }
else { axisX = lambdaMajor - c11; axisY = c01; if (axisX * axisX + axisY * axisY <= 0.000000000001f) { axisX = c01; axisY = lambdaMajor - c00; } }
float axisLength = sqrt(axisX * axisX + axisY * axisY);
if (!isfinite(axisLength) || axisLength <= 0.000001f) return out;
out.axisX = axisX / axisLength;
out.axisY = axisY / axisLength;
out.filterWidth = LGBOClamp(major, 1.0f, 4.0f);
out.tapCount = major <= 2.5f ? 2 : 4;
}

float2 localButtonSourceUV(texture2d<float, access::sample> src,
                           constant Uniforms &u, float2 targetUV) {
    if (u.buttonSourceOverscanEnabled <= 0.5f) return targetUV;
    return float2(
        LGBOMapTargetUVToSource(targetUV.x,u.resolution.x,(float)src.get_width(),u.buttonSourceTargetOriginPixels.x,true),
        LGBOMapTargetUVToSource(targetUV.y,u.resolution.y,(float)src.get_height(),u.buttonSourceTargetOriginPixels.y,true));
}

float2 localButtonCandidateTargetUV(LGButtonOpticsResult q, float2 point,
                                    bool environmentPath, constant Uniforms &u) {
    if (u.buttonSourceOverscanEnabled > 0.5f) {
        float2 offset = environmentPath
            ? float2(q.environmentOffsetX,q.environmentOffsetY)
            : float2(q.offsetX,q.offsetY);
        return (point + offset) / u.resolution;
    }
    return environmentPath ? float2(q.environmentU,q.environmentV)
                           : float2(q.sampleU,q.sampleV);
}

LGButtonOpticsResult localButtonEvaluateAt(float2 point, float width, float height,
                                           float bezel, constant Uniforms &u) {
    return LGButtonOpticsEvaluateWithContact(
        point.x,point.y,width,height,u.buttonCandidateCenter.x,
        u.buttonCandidateCenter.y,u.buttonCandidateCornerRadius,bezel,
        u.glassThickness,u.refractiveIndex,u.refractionScale,
        u.buttonCandidateMaxOffset,u.buttonCandidatePointScale,
        u.buttonCandidateRendererScale,true,u.buttonContactEnabled > 0.5f,
        u.buttonContactCenter.x,u.buttonContactCenter.y,
        u.buttonContactPressure);
}

float2 localButtonSourceTexels(texture2d<float, access::sample> src,
                               constant Uniforms &u, LGButtonOpticsResult q,
                               float2 point, bool environmentPath) {
    float2 targetUV=localButtonCandidateTargetUV(q,point,environmentPath,u);
    return localButtonSourceUV(src,u,targetUV) *
           float2((float)src.get_width(),(float)src.get_height());
}

float4 localButtonMinifiedSample(texture2d<float, access::sample> source,
                                 sampler s, float2 sourceUV,
                                 LGMinificationFootprint footprint) {
    float2 dimensions=float2((float)source.get_width(),(float)source.get_height());
    float2 halfTexel=0.5f/dimensions;
    float2 highUV=1.0f-halfTexel;
    if (footprint.tapCount!=2 && footprint.tapCount!=4)
        return source.sample(s,sourceUV,level(0.0f));
    if (footprint.tapCount==2) {
        float2 delta=float2(footprint.axisX,footprint.axisY);
        delta*=0.25f*footprint.filterWidth;
        delta/=dimensions;
        float2 uv0=clamp(sourceUV-delta,halfTexel,highUV);
        float2 uv1=clamp(sourceUV+delta,halfTexel,highUV);
        return 0.5f*(source.sample(s,uv0,level(0.0f))+
                     source.sample(s,uv1,level(0.0f)));
    }
    float2 axis= float2(footprint.axisX,footprint.axisY);
    float2 d=axis*(0.125f*footprint.filterWidth)/dimensions;
    float2 a=clamp(sourceUV-axis*(0.375f*footprint.filterWidth)/dimensions,halfTexel,highUV);
    float2 b=clamp(sourceUV-d,halfTexel,highUV);
    float2 c=clamp(sourceUV+d,halfTexel,highUV);
    float2 e=clamp(sourceUV+axis*(0.375f*footprint.filterWidth)/dimensions,halfTexel,highUV);
    return 0.25f*(source.sample(s,a,level(0.0f))+
                  source.sample(s,b,level(0.0f))+
                  source.sample(s,c,level(0.0f))+
                  source.sample(s,e,level(0.0f)));
}

#endif

float quartzGlassEdgeProfile(float distanceFromEdge,
                             float refractionHeight) {
    float t = saturate(distanceFromEdge / max(refractionHeight, 0.001));
    return 1.0 - sqrt(t * (2.0 - t));
}

float quartzGlassHighlight(float distanceFromEdge,
                           float bezelWidth,
                           float2 surfaceNormal,
                           float strength,
                           float angle) {
    float normalLength = max(length(surfaceNormal), 0.001);
    float2 normal = surfaceNormal / normalLength;
    float ringWidth = clamp(bezelWidth * 0.24, 1.0, 2.5);
    float aa = 1.0;

    float outerCoverage = saturate(distanceFromEdge / aa + 0.5);
    float innerCoverage = saturate((ringWidth - distanceFromEdge) / aa + 0.5);
    float ring = outerCoverage * innerCoverage;
    float radial = saturate(distanceFromEdge / ringWidth);
    ring *= 1.0 - radial;

    float2 lightDirection = float2(cos(angle), sin(angle));
    float threshold = 0.15;
    float directional = saturate((dot(lightDirection, normal) - threshold) /
                                 max(1.0 - threshold, 0.0001));
    float highlight = ring * directional;

    float oppositeAttenuation = 1.35;
    highlight /= max(1.0 + (1.0 - highlight) * oppositeAttenuation,
                     0.0001);
    return highlight * max(strength, 0.0);
}

float linearize(float c) {
    return c > 0.04045 ? pow((c + 0.055) / 1.055, 2.4) : c / 12.92;
}
float gammaEncode(float c) {
    return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}

float3 srgbToXyz(float3 rgb) {
    float3 l = float3(linearize(rgb.r), linearize(rgb.g), linearize(rgb.b));
    return float3(dot(l, float3(0.4124, 0.3576, 0.1805)),
                  dot(l, float3(0.2126, 0.7152, 0.0722)),
                  dot(l, float3(0.0193, 0.1192, 0.9505)));
}
float3 xyzToSrgb(float3 xyz) {
    float3 l = float3(dot(xyz, float3( 3.2406,-1.5372,-0.4986)),
                      dot(xyz, float3(-0.9689, 1.8758, 0.0415)),
                      dot(xyz, float3( 0.0557,-0.2040, 1.0570)));
    return clamp(float3(gammaEncode(l.r), gammaEncode(l.g), gammaEncode(l.b)), 0.0, 1.0);
}

float labF(float t)    { float t3 = t*t*t; return t3>0.008856? pow(t,1.0/3.0) : 7.787*t+16.0/116.0; }
float labInvF(float t) { float t3 = t*t*t; return t3>0.008856? t3 : (t-16.0/116.0)/7.787; }

float3 xyzToLab(float3 xyz) {
    float3 n = xyz / float3(0.95047, 1.0, 1.08883);
    float fx = labF(n.x), fy = labF(n.y), fz = labF(n.z);
    return float3(116.0*fy - 16.0, 500.0*(fx-fy), 200.0*(fy-fz));
}
float3 labToXyz(float3 lab) {
    float fy = (lab.x+16.0)/116.0, fx = fy+lab.y/500.0, fz = fy-lab.z/200.0;
    return float3(0.95047*labInvF(fx), labInvF(fy), 1.08883*labInvF(fz));
}
float3 srgbToLch(float3 rgb) {
    float3 lab = xyzToLab(srgbToXyz(rgb));
    return float3(lab.x, length(lab.yz), atan2(lab.z, lab.y));
}
float3 lchToSrgb(float3 lch) {
    float3 lab = float3(lch.x, cos(lch.z)*lch.y, sin(lch.z)*lch.y);
    return xyzToSrgb(labToXyz(lab));
}

float bottomRoundedBoxDistance(float2 point, float2 size, float radius) {
    float2 halfSize = size * 0.5;
    float2 centered = point - halfSize;
    float selectedRadius = centered.y > 0.0 ? radius : 0.0;
    float2 q = abs(centered) - halfSize + selectedRadius;
    return min(max(q.x, q.y), 0.0)
         + length(max(q, float2(0.0))) - selectedRadius;
}

float2 backdropSampleUV(float2 capturePx,
                        float2 logicalPx,
                        float2 displacementPx,
                        bool isCoverSheet,
                        constant Uniforms &u,
                        float zoomMix)
{
    float2 sampleUV;
    if (isCoverSheet) {
        sampleUV = (capturePx + displacementPx) / u.resolution;
    } else {
        float2 screenPx = u.cardOrigin + logicalPx + displacementPx;
        float2 mapped   = u.samplingTransformOffset
                        + screenPx.x * u.samplingTransformX
                        + screenPx.y * u.samplingTransformY;
        float2 imgPx    = mapped - u.wallpaperOrigin;
        sampleUV = imgPx / u.wallpaperResolution;

        int ori = int(round(u.samplingOrientation));
        if      (ori == 2) sampleUV = float2(1.0 - sampleUV.x, 1.0 - sampleUV.y);
        else if (ori == 3) sampleUV = float2(1.0 - sampleUV.y,       sampleUV.x);
        else if (ori == 4) sampleUV = float2(      sampleUV.y,  1.0 - sampleUV.x);
    }

    float zoom = max(u.backdropZoom, 0.01);
    if (u.shapeSize.x > 0.5 && u.shapeSize.y > 0.5) {
        float eased = mix(1.0, zoom, clamp(zoomMix, 0.0, 1.0));
        float2 centre = (u.shapeOrigin + u.shapeSize * 0.5) / u.resolution;
        sampleUV.y = centre.y + (sampleUV.y - centre.y) / eased;
    } else if (clamp(u.shapeScale, 0.05, 1.0) < 0.999) {
        sampleUV.y = 0.5 + (sampleUV.y - 0.5) / zoom;
    } else {
        sampleUV = float2(0.5) + (sampleUV - float2(0.5)) / zoom;
    }
    return clamp(sampleUV, 0.0, 1.0);
}

float4 liquidGlassPixel(texture2d<float, access::sample> src,
                        texture2d<float, access::sample> glyphMask,
                        constant Uniforms &u, uint2 gid, uint2 dimensions)
{
    const uint W = dimensions.x, H = dimensions.y;

    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 localUV = (float2(gid) + 0.5) / float2(W, H);
    bool isCoverSheet = u.useGlyphMask < -0.5;
    bool isKeyboard = u.useGlyphMask > 0.0 && u.useGlyphMask < 0.5;
    float2 captureUV = localUV;
    float2 capturePx = localUV * u.resolution;
    float2 px = capturePx;
    float fw = u.resolution.x, fh = u.resolution.y;
    float coverOrientation = isCoverSheet ? -u.useGlyphMask : 0.0;
    if (isCoverSheet && coverOrientation == 2.0) {

        px = float2(u.resolution.x - capturePx.x,
                    u.resolution.y - capturePx.y);
    } else if (isCoverSheet && coverOrientation == 3.0) {

        px = float2(capturePx.y, u.resolution.x - capturePx.x);
        fw = u.resolution.y;
        fh = u.resolution.x;
    } else if (isCoverSheet && coverOrientation == 4.0) {

        px = float2(u.resolution.y - capturePx.y, capturePx.x);
        fw = u.resolution.y;
        fh = u.resolution.x;
    }
    float  R        = u.radius, bezel = u.bezelWidth;
    float  eta      = 1.0 / u.refractiveIndex;
    float  shortest = min(fw, fh);

    float signedDistance;
    float distFromSide;
    float2 dir;
    float edgeOpacity;
    bool subShape = false;
    float cornerBlend = 0.0;
    if (u.useGlyphMask > 0.5) {

        float bestDistance = bezel + 1.0;
        float2 bestDirection = float2(0.0, -1.0);
        constexpr int directionCount = 12;
        for (int directionIndex = 0; directionIndex < directionCount; directionIndex++) {
            float angle = (6.28318530718 * float(directionIndex)) / float(directionCount);
            float2 candidateDirection = float2(cos(angle), sin(angle));
            float low = 0.0;
            float high = bezel + 1.0;
            float probe = 1.0;
            for (int level = 0; level < 6; level++) {
                probe = min(probe, bezel);
                float2 probeUV = localUV + candidateDirection * (probe / u.resolution);
                if (glyphMask.sample(s, probeUV).r < 0.15) {
                    high = probe;
                    break;
                }
                low = probe;
                probe *= 2.0;
            }
            if (high <= bezel) {
                for (int refinement = 0; refinement < 3; refinement++) {
                    float middle = (low + high) * 0.5;
                    float2 probeUV = localUV + candidateDirection * (middle / u.resolution);
                    if (glyphMask.sample(s, probeUV).r < 0.15) high = middle;
                    else low = middle;
                }
                if (high < bestDistance) {
                    bestDistance = high;
                    bestDirection = candidateDirection;
                }
            }
        }
        signedDistance = -bestDistance;
        distFromSide = bestDistance;
        dir = bestDirection;

        edgeOpacity = 1.0;
    } else {

        R = clamp(R, 0.0, shortest * 0.5);

        float shapeScale = clamp(u.shapeScale, 0.05, 1.0);
        float2 shapeInset = float2(0.0);
        if (u.shapeSize.x > 0.5 && u.shapeSize.y > 0.5) {
            subShape = true;
            shapeInset = u.shapeOrigin;
            fw = u.shapeSize.x;
            fh = u.shapeSize.y;
            shortest = min(fw, fh);
            R = clamp(R, 0.0, shortest * 0.5);
        } else if (shapeScale < 0.999) {
            subShape = true;
            shapeInset = float2(fw, fh) * (1.0 - shapeScale) * 0.5;
            fw *= shapeScale;
            fh *= shapeScale;
            shortest = min(fw, fh);
            R = clamp(R, 0.0, shortest * 0.5);
        }

        float2 lensPx = px - (isCoverSheet ? u.lensOrigin : shapeInset);
        if (isKeyboard) {
            fh += max(R, bezel);
            shortest = min(fw, fh);
        }
        float2 halfSize = float2(fw, fh) * 0.5;
        float2 p = lensPx - halfSize;
        float2 core;
        cornerBlend = 0.0;
        if (isCoverSheet) {

            R = min(R, shortest * 0.5);
            core = halfSize;
            signedDistance = bottomRoundedBoxDistance(
                lensPx, float2(fw, fh), R);
        } else if (R >= shortest * 0.49 || R < 0.5) {
            core = max(halfSize - float2(R), float2(0.0));
            float2 q = abs(p) - core;
            signedDistance = length(max(q, float2(0.0)))
                           + min(max(q.x, q.y), 0.0) - R;
            cornerBlend = saturate(min(q.x, q.y) / max(R, 0.001));
        } else {
            constexpr float continuousCornerExtent = 1.528;
            float2 extent = min(float2(R * continuousCornerExtent), halfSize);
            core = max(halfSize - extent, float2(0.0));
            float2 q = abs(p) - core;
            float2 corner = max(q, float2(0.0));
            float2 normalized = corner / max(extent, float2(0.001));
            float superLength = pow(pow(normalized.x, 4.0) +
                                    pow(normalized.y, 4.0), 0.25);
            if (q.x <= 0.0 && q.y <= 0.0) {

                signedDistance = -min(halfSize.x - abs(p.x),
                                      halfSize.y - abs(p.y));
            } else {
                signedDistance = (superLength - 1.0) * min(extent.x, extent.y);
            }
            cornerBlend = saturate(min(q.x, q.y) /
                                   max(min(extent.x, extent.y), 0.001));
        }
        if (signedDistance > (subShape ? 0.0 : 1.0)) {
            return subShape ? float4(0.0) : src.sample(s, localButtonSourceUV(src, u,  captureUV));
        }

        distFromSide = max(0.0, -signedDistance);
        float2 cornerDelta = max(abs(p) - core, float2(0.0));
        float2 normalDelta;
        if (isCoverSheet) {
            float2 size = float2(fw, fh);
            float dx = bottomRoundedBoxDistance(
                           lensPx + float2(1.0, 0.0), size, R)
                     - bottomRoundedBoxDistance(
                           lensPx - float2(1.0, 0.0), size, R);
            float dy = bottomRoundedBoxDistance(
                           lensPx + float2(0.0, 1.0), size, R)
                     - bottomRoundedBoxDistance(
                           lensPx - float2(0.0, 1.0), size, R);
            normalDelta = float2(dx, dy);
        } else if (R < shortest * 0.49 && R >= 0.5 &&
            cornerDelta.x > 0.0 && cornerDelta.y > 0.0) {
            float2 t = cornerDelta / max(cornerDelta.x + cornerDelta.y, 0.0001);
            normalDelta = sign(p) * t;
        } else {
            float2 nearestCore = clamp(p, -core, core);
            normalDelta = p - nearestCore;
        }
        float normalLength = length(normalDelta);
        if (normalLength > 0.001) {
            dir = normalDelta / normalLength;
        } else {
            float dL = lensPx.x, dR = fw - lensPx.x;
            float dT = lensPx.y, dB = fh - lensPx.y;
            float dm = min(min(dL, dR), min(dT, dB));
            dir = float2((dL < dR && dL == dm) ? -1.0 : (dR <= dL && dR == dm) ?  1.0 : 0.0,
                         (dT < dB && dT == dm) ? -1.0 : (dB <= dT && dB == dm) ?  1.0 : 0.0);
        }
        edgeOpacity = subShape ? 1.0
                               : clamp(1.0 - max(0.0, signedDistance), 0.0, 1.0);
    }

#if LG_BUTTON_OPTICS_COMPILED
    bool buttonCandidate = u.buttonCandidate > 0.5 &&
                           u.buttonCandidateMaxOffset > 0.0;
    if (buttonCandidate) {
        if (subShape || isCoverSheet || isKeyboard || u.useGlyphMask != 0.0)
            return src.sample(s, localButtonSourceUV(src, u,  captureUV));
        LGButtonOpticsResult optics = LGButtonOpticsEvaluateWithContact(
            px.x, px.y, fw, fh, u.buttonCandidateCenter.x,
            u.buttonCandidateCenter.y, u.buttonCandidateCornerRadius,
            bezel, u.glassThickness, u.refractiveIndex,
            u.refractionScale, u.buttonCandidateMaxOffset,
            u.buttonCandidatePointScale, u.buttonCandidateRendererScale, true,
            u.buttonContactEnabled > 0.5f, u.buttonContactCenter.x,
            u.buttonContactCenter.y, u.buttonContactPressure);
        if (!optics.valid || optics.signedDistance >= 0.0f)
            return src.sample(s, localButtonSourceUV(src, u,  captureUV));
        float2 opticalUV = float2(optics.sampleU, optics.sampleV);
        if (u.buttonSourceOverscanEnabled > 0.5f)
            opticalUV=(capturePx+float2(optics.offsetX,optics.offsetY))/u.resolution;

        LGButtonOpticsResult localButtonMinusX = localButtonEvaluateAt(float2(px.x-0.5f,px.y),fw,fh,bezel,u);
        LGButtonOpticsResult localButtonPlusX  = localButtonEvaluateAt(float2(px.x+0.5f,px.y),fw,fh,bezel,u);
        LGButtonOpticsResult localButtonMinusY = localButtonEvaluateAt(float2(px.x,px.y-0.5f),fw,fh,bezel,u);
        LGButtonOpticsResult localButtonPlusY  = localButtonEvaluateAt(float2(px.x,px.y+0.5f),fw,fh,bezel,u);
        float2 localOpticalMinusX=localButtonSourceTexels(src,u,localButtonMinusX,float2(px.x-0.5f,px.y),false);
        float2 localOpticalPlusX =localButtonSourceTexels(src,u,localButtonPlusX, float2(px.x+0.5f,px.y),false);
        float2 localOpticalMinusY=localButtonSourceTexels(src,u,localButtonMinusY,float2(px.x,px.y-0.5f),false);
        float2 localOpticalPlusY =localButtonSourceTexels(src,u,localButtonPlusY, float2(px.x,px.y+0.5f),false);
        float2 localEnvironmentMinusX=localButtonSourceTexels(src,u,localButtonMinusX,float2(px.x-0.5f,px.y),true);
        float2 localEnvironmentPlusX =localButtonSourceTexels(src,u,localButtonPlusX, float2(px.x+0.5f,px.y),true);
        float2 localEnvironmentMinusY=localButtonSourceTexels(src,u,localButtonMinusY,float2(px.x,px.y-0.5f),true);
        float2 localEnvironmentPlusY =localButtonSourceTexels(src,u,localButtonPlusY, float2(px.x,px.y+0.5f),true);
        LGMinificationFootprint opticalFootprint=LGBOAnalyzeMinificationFootprint(
            localOpticalPlusX.x-localOpticalMinusX.x,localOpticalPlusX.y-localOpticalMinusX.y,
            localOpticalPlusY.x-localOpticalMinusY.x,localOpticalPlusY.y-localOpticalMinusY.y);
        LGMinificationFootprint environmentFootprint=LGBOAnalyzeMinificationFootprint(
            localEnvironmentPlusX.x-localEnvironmentMinusX.x,localEnvironmentPlusX.y-localEnvironmentMinusX.y,
            localEnvironmentPlusY.x-localEnvironmentMinusY.x,localEnvironmentPlusY.y-localEnvironmentMinusY.y);

        float4 opticalSample;
        if (opticalFootprint.tapCount > 1)
            opticalSample=localButtonMinifiedSample(src,s,localButtonSourceUV(src,u,opticalUV),opticalFootprint);
        else
            opticalSample=src.sample(s,localButtonSourceUV(src,u,opticalUV));
        if (opticalSample.a < 0.01f) opticalSample = src.sample(s, localButtonSourceUV(src, u,  captureUV));
        /* Source-plane radiance approximation: a second low-cost sample from
         * the same live CA origTex. This is not an external environment map. */
        float2 environmentUV = float2(optics.environmentU, optics.environmentV);
        if (u.buttonSourceOverscanEnabled > 0.5f)
            environmentUV=(capturePx+float2(optics.environmentOffsetX,optics.environmentOffsetY))/u.resolution;
        float4 environmentSample;
        if (environmentFootprint.tapCount > 1)
            environmentSample=localButtonMinifiedSample(src,s,localButtonSourceUV(src,u,environmentUV),environmentFootprint);
        else
            environmentSample=src.sample(s,localButtonSourceUV(src,u,environmentUV));
        if (environmentSample.a < 0.01f) environmentSample = opticalSample;
        float environmentWeight = clamp(optics.environmentWeight, 0.0f, 0.28f);
        float3 mixedPremul = float3(
            LGBOEnvironmentMixPremultipliedChannel(opticalSample.r, opticalSample.a, environmentSample.r, environmentSample.a, environmentWeight),
            LGBOEnvironmentMixPremultipliedChannel(opticalSample.g, opticalSample.a, environmentSample.g, environmentSample.a, environmentWeight),
            LGBOEnvironmentMixPremultipliedChannel(opticalSample.b, opticalSample.a, environmentSample.b, environmentSample.a, environmentWeight));
        return float4(mixedPremul, opticalSample.a);
    }
#endif

    if (u.useGlyphMask < 0.5 && !isCoverSheet && !isKeyboard &&
        R >= 0.5 && bezel > R) {
        float cornerScale = R >= shortest * 0.49 ? R
                                                 : min(R * 1.528, shortest * 0.5);
        float taper = cornerBlend * cornerBlend * (3.0 - 2.0 * cornerBlend);
        bezel = mix(bezel, min(bezel, cornerScale), taper);
    }

    if ((R < shortest * 0.45 || subShape) && distFromSide >= bezel) {
        float4 flat = src.sample(s, localButtonSourceUV(src, u,  captureUV));
        flat.rgb = mix(flat.rgb, u.tintColor.rgb, u.tintColor.a);
        return flat;
    }

    float normDisp = (distFromSide < bezel) ?
        quartzGlassEdgeProfile(distFromSide,
                               min(max(u.glassThickness, 1.0), bezel)) : 0.0;
    if ((isCoverSheet && dir.y <= -abs(dir.x)) ||
        (isKeyboard && dir.y >= abs(dir.x))) normDisp = 0.0;

    float2 textureDir = dir;
    if (isCoverSheet && coverOrientation == 2.0) {

        textureDir = -dir;
    } else if (isCoverSheet && coverOrientation == 3.0) {

        textureDir = float2(-dir.y, dir.x);
    } else if (isCoverSheet && coverOrientation == 4.0) {

        textureDir = float2(dir.y, -dir.x);
    }
    float2 dispPx = -textureDir * normDisp * bezel
                  * u.refractionScale * edgeOpacity;
    float dispersion = clamp(u.dispersionStrength, 0.0, 20.0);
    constexpr float zoomRampSpan = 0.3;
    float zoomMix = bezel > 0.001
        ? clamp((1.0 - distFromSide / bezel) / zoomRampSpan, 0.0, 1.0) : 0.0;
    zoomMix = zoomMix * zoomMix * (3.0 - 2.0 * zoomMix);
    float2 greenUV = backdropSampleUV(capturePx, px, dispPx,
                                      isCoverSheet, u, zoomMix);
    float4 greenSample = src.sample(s, localButtonSourceUV(src, u,  greenUV));

    float4 fallback = float4(0.0);
    bool loadedFallback = false;
    if (greenSample.a < 0.01) {
        fallback = src.sample(s, localButtonSourceUV(src, u,  captureUV));
        loadedFallback = true;
        greenSample = fallback;
    }
    if (greenSample.a < 0.01) return float4(0.0);

    float4 bg = greenSample;
    if (dispersion > 0.001 && dot(dispPx, dispPx) > 0.0001) {
        float2 aberrationPx = -textureDir * normDisp * dispersion * 8.0 * edgeOpacity;
        float3 accumulated = float3(0.0);
        float accumulatedAlpha = 0.0;

        for (int i = 0; i < 3; i++) {
            float weight = 1.0 - float(i) / 3.0;
            float2 uv = backdropSampleUV(capturePx, px,
                                          dispPx + aberrationPx * weight,
                                          isCoverSheet, u, zoomMix);
            float4 sample = src.sample(s, localButtonSourceUV(src, u,  uv));
            if (sample.a < 0.01) {
                if (!loadedFallback) {
                    fallback = src.sample(s, localButtonSourceUV(src, u,  captureUV));
                    loadedFallback = true;
                }
                sample = fallback;
            }
            accumulated.r += sample.r * weight;
            accumulated.g += sample.g * (1.0 - weight);
            accumulatedAlpha += sample.a;
        }

        for (int i = 0; i < 4; i++) {
            float weight = float(i) / 3.0;
            float2 uv = backdropSampleUV(capturePx, px,
                                          dispPx - aberrationPx * weight,
                                          isCoverSheet, u, zoomMix);
            float4 sample = src.sample(s, localButtonSourceUV(src, u,  uv));
            if (sample.a < 0.01) {
                if (!loadedFallback) {
                    fallback = src.sample(s, localButtonSourceUV(src, u,  captureUV));
                    loadedFallback = true;
                }
                sample = fallback;
            }
            accumulated.g += sample.g * (1.0 - weight);
            accumulated.b += sample.b * weight;
            accumulatedAlpha += sample.a;
        }

        bg.rgb = accumulated * float3(0.5, 1.0 / 3.0, 0.5);
        bg.a = accumulatedAlpha / 7.0;
    }

    float3 outRGB = mix(bg.rgb, u.tintColor.rgb, u.tintColor.a);
    float highlight = quartzGlassHighlight(distFromSide, bezel, dir,
                                           u.fresnelGlareStrength,
                                           -0.78539816339) *
                      edgeOpacity;
    float luminance = dot(outRGB, float3(0.2126, 0.7152, 0.0722));
    highlight *= mix(0.32, 1.0, luminance);
    highlight = min(highlight, 0.22);
    outRGB = 1.0 - (1.0 - outRGB) * (1.0 - highlight);
    if (subShape && distFromSide <= u.borderWidthPixels)
        outRGB = 1.0 - (1.0 - outRGB) * 0.82;
    return float4(outRGB, edgeOpacity);
}

struct LGVertexOut {
    float4 position [[position]];
};

vertex LGVertexOut liquidGlassVertex(uint vertexID [[vertex_id]])
{
    constexpr float2 positions[] = {
        float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0)
    };
    LGVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    return out;
}

fragment float4 liquidGlassFragment(
    LGVertexOut in [[stage_in]],
    texture2d<float, access::sample> src [[texture(0)]],
    texture2d<float, access::sample> glyphMask [[texture(1)]],
    constant Uniforms &u [[buffer(0)]])
{
    if (u.buttonSourceOverscanEnabled > 0.5f) {
        float2 targetPosition=in.position.xy-(u.outputResolution-u.resolution)*0.5f;
        if (any(targetPosition<float2(0.0f)) || any(targetPosition>=u.resolution))
            return float4(0.0f);
        uint2 targetDimensions=max(uint2(u.resolution),uint2(1));
        uint2 targetGid=min(uint2(targetPosition),targetDimensions-1);
        return liquidGlassPixel(src,glyphMask,u,targetGid,targetDimensions);
    }
    uint2 dimensions(src.get_width(), src.get_height());
    float2 sourcePosition =
        in.position.xy - (u.outputResolution - u.resolution) * 0.5;
    if (any(sourcePosition < float2(0.0)) ||
        any(sourcePosition >= u.resolution)) return float4(0.0);
    uint2 gid = min(uint2(sourcePosition), dimensions - 1);
    return liquidGlassPixel(src, glyphMask, u, gid, dimensions);
}

