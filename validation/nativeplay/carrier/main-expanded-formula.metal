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
LGButtonOpticsResult LGButtonOpticsEvaluate(float x, float y, float width, float height, float centerX, float centerY, float radius, float bezel, float glassThickness, float refractiveIndex, float refractionScale, float displacementCap, float pointScale, float rendererScale, bool enabled) {
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
float edgeT = LGBOClamp(depth / LGBOMax(bezel, 1.0f), 0.0f, 1.0f);
float edgeFade = edgeT * edgeT * (3.0f - 2.0f * edgeT);
float denominator = LGBOMax(-rayZ, 0.25f);
float offsetX = rayX / denominator * pathLength * refractionScale * edgeFade;
float offsetY = rayY / denominator * pathLength * refractionScale * edgeFade;
float offsetLength = LGBOHypot(offsetX, offsetY);
if (!isfinite(offsetLength)) { out.valid = false; return out; }
if (offsetLength > displacementCap && offsetLength > 0.0f) { float factor = displacementCap / offsetLength; offsetX *= factor; offsetY *= factor; }
out.offsetX = offsetX;
out.offsetY = offsetY;
out.sampleU = LGBOClamp(x + offsetX, 0.5f, width - 0.5f) / width;
out.sampleV = LGBOClamp(y + offsetY, 0.5f, height - 0.5f) / height;
float normalCosine = LGBOClamp(normalZ, 0.0f, 1.0f);
float fresnelBaseRatio = (refractiveIndex - 1.0f) / (refractiveIndex + 1.0f);
float fresnelBase = fresnelBaseRatio * fresnelBaseRatio;
float fresnelEdge = fresnelBase + (1.0f - fresnelBase) * pow(1.0f - normalCosine, 5.0f);
float thicknessCoverage = LGBOClamp(glassThickness / LGBOMax(bezel, 1.0f), 0.0f, 1.0f);
float environmentEdgeCoverage = LGBOClamp(depth / LGBOMax(pointScale * 0.75f, 1.0f), 0.0f, 1.0f);
out.environmentWeight = LGBOMin(fresnelEdge * environmentEdgeCoverage * thicknessCoverage, 0.28f);
float reflectedZ = 2.0f * normalZ * normalZ - 1.0f;
float reflectedDenominator = LGBOMax(LGBOAbs(reflectedZ), 0.65f);
float reflectedX = 2.0f * normalZ * normalX / reflectedDenominator;
float reflectedY = 2.0f * normalZ * normalY / reflectedDenominator;
float thicknessPathFraction = 0.35f + 0.65f * edgeT;
float environmentPath = LGBOMin(glassThickness, LGBOMax(bezel, 1.0f)) * 0.38f * refractionScale * thicknessPathFraction;
float environmentOffsetX = reflectedX * environmentPath;
float environmentOffsetY = reflectedY * environmentPath;
float environmentLength = LGBOHypot(environmentOffsetX, environmentOffsetY);
float environmentCap = LGBOMin(displacementCap * 0.45f, LGBOMin(glassThickness, LGBOMax(bezel, 1.0f)) * 0.38f);
if (!isfinite(environmentLength) || !isfinite(out.environmentWeight)) { out.valid = false; return out; }
if (environmentLength > environmentCap && environmentLength > 0.0f) { float factor = environmentCap / environmentLength; environmentOffsetX *= factor; environmentOffsetY *= factor; }
out.environmentU = LGBOClamp(x + environmentOffsetX, 0.5f, width - 0.5f) / width;
out.environmentV = LGBOClamp(y + environmentOffsetY, 0.5f, height - 0.5f) / height;
return out;
}
float LGBOEnvironmentMixPremultipliedChannel(float transmittedPremul, float transmittedAlpha, float environmentPremul, float environmentAlpha, float weight) {
float alpha = LGBOClamp(transmittedAlpha, 0.0f, 1.0f);
if (alpha <= 0.00001f) return 0.0f;
float transmittedStraight = LGBOClamp(transmittedPremul / alpha, 0.0f, 1.0f);
float reflectedAlpha = LGBOClamp(environmentAlpha, 0.0f, 1.0f);
float reflectedStraight = reflectedAlpha > 0.00001f ? LGBOClamp(environmentPremul / reflectedAlpha, 0.0f, 1.0f) : transmittedStraight;
float boundedWeight = LGBOClamp(weight, 0.0f, 0.28f);
float straightResult = transmittedStraight + (reflectedStraight - transmittedStraight) * boundedWeight;
return LGBOClamp(straightResult, 0.0f, 1.0f) * alpha;
}
