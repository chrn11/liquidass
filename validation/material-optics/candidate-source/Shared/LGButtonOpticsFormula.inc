/*
 * One source body is compiled as ordinary C for CPU contract tests and is
 * stringified into the runtime MSL passed to newLibraryWithSource:. Keep every
 * function/statement in this file inside the LGBO_* DSL macros.
 */
LGBO_STRUCT_BEGIN(LGButtonOpticsResult)
LGBO_FIELD(float, signedDistance)
LGBO_FIELD(float, offsetX)
LGBO_FIELD(float, offsetY)
LGBO_FIELD(float, height)
LGBO_FIELD(float, normalX)
LGBO_FIELD(float, normalY)
LGBO_FIELD(float, sampleU)
LGBO_FIELD(float, sampleV)
LGBO_FIELD(float, environmentU)
LGBO_FIELD(float, environmentV)
LGBO_FIELD(float, environmentWeight)
/* Bounded raw displacement, in target-local texels. Only local overscan uses
 * these; original clamped U/V remain exactly the old no-overscan path. */
LGBO_FIELD(float, environmentOffsetX)
LGBO_FIELD(float, environmentOffsetY)
LGBO_FIELD(bool, valid)
LGBO_STRUCT_END(LGButtonOpticsResult)

LGBO_FUNCTION_BEGIN(float, LGBOAbs, (float x))
LGBO_STMT(return x < 0.0f ? -x : x;)
LGBO_FUNCTION_END

LGBO_FUNCTION_BEGIN(float, LGBOMin, (float a, float b))
LGBO_STMT(return a < b ? a : b;)
LGBO_FUNCTION_END

LGBO_FUNCTION_BEGIN(float, LGBOMax, (float a, float b))
LGBO_STMT(return a > b ? a : b;)
LGBO_FUNCTION_END

LGBO_FUNCTION_BEGIN(float, LGBOClamp, (float x, float lo, float hi))
LGBO_STMT(return LGBOMin(LGBOMax(x, lo), hi);)
LGBO_FUNCTION_END

LGBO_FUNCTION_BEGIN(float, LGBOHypot, (float x, float y))
LGBO_STMT(return sqrt(x * x + y * y);)
LGBO_FUNCTION_END

/* C1 radial limiter: exact through 75% of cap, then approaches (never
 * exceeds) cap with zero slope. Unlike hard min(cap/r), it has no slope kink. */
LGBO_FUNCTION_BEGIN(float, LGBOSmoothCappedLength, (float rawLength, float cap))
LGBO_STMT(if (!isfinite(rawLength) || !isfinite(cap) || rawLength <= 0.0f || cap <= 0.0f) return 0.0f;)
LGBO_STMT(float shoulder = cap * 0.25f;)
LGBO_STMT(float start = cap - shoulder;)
LGBO_STMT(if (rawLength <= start) return rawLength;)
LGBO_STMT(float excess = rawLength - start;)
LGBO_STMT(return start + shoulder * excess / (shoulder + excess);)
LGBO_FUNCTION_END

LGBO_FUNCTION_BEGIN(float, LGBOButtonRoundedBoxSDF, (float x, float y, float width, float height, float radius))
LGBO_STMT(float halfWidth = width * 0.5f;)
LGBO_STMT(float halfHeight = height * 0.5f;)
LGBO_STMT(float qx = LGBOAbs(x) - (halfWidth - radius);)
LGBO_STMT(float qy = LGBOAbs(y) - (halfHeight - radius);)
LGBO_STMT(float outsideX = LGBOMax(qx, 0.0f);)
LGBO_STMT(float outsideY = LGBOMax(qy, 0.0f);)
LGBO_STMT(float outside = LGBOHypot(outsideX, outsideY);)
LGBO_STMT(float inside = LGBOMin(LGBOMax(qx, qy), 0.0f);)
LGBO_STMT(return outside + inside - radius;)
LGBO_FUNCTION_END

LGBO_FUNCTION_BEGIN(LGButtonOpticsResult, LGButtonOpticsEvaluateWithContact, (float x, float y, float width, float height, float centerX, float centerY, float radius, float bezel, float glassThickness, float refractiveIndex, float refractionScale, float displacementCap, float pointScale, float rendererScale, bool enabled, bool contactEnabled, float contactX, float contactY, float contactPressure))
LGBO_STMT(LGButtonOpticsResult out;)
LGBO_STMT(out.signedDistance = 0.0f;)
LGBO_STMT(out.offsetX = 0.0f;)
LGBO_STMT(out.offsetY = 0.0f;)
LGBO_STMT(out.height = 0.0f;)
LGBO_STMT(out.normalX = 0.0f;)
LGBO_STMT(out.normalY = 0.0f;)
LGBO_STMT(out.sampleU = 0.0f;)
LGBO_STMT(out.sampleV = 0.0f;)
LGBO_STMT(out.environmentU = 0.0f;)
LGBO_STMT(out.environmentV = 0.0f;)
LGBO_STMT(out.environmentWeight = 0.0f;)
LGBO_STMT(out.environmentOffsetX = 0.0f;)
LGBO_STMT(out.environmentOffsetY = 0.0f;)
LGBO_STMT(out.valid = false;)
LGBO_STMT(if (!isfinite(x) || !isfinite(y) || !isfinite(width) || !isfinite(height) || !isfinite(centerX) || !isfinite(centerY) || !isfinite(radius) || !isfinite(bezel) || !isfinite(glassThickness) || !isfinite(refractiveIndex) || !isfinite(refractionScale) || !isfinite(displacementCap) || !isfinite(pointScale) || !isfinite(rendererScale)) return out;)
LGBO_STMT(float shortest = LGBOMin(width, height);)
LGBO_STMT(if (width < 1.0f || height < 1.0f || width > 16384.0f || height > 16384.0f || shortest < 1.0f || centerX < 0.5f || centerX > width - 0.5f || centerY < 0.5f || centerY > height - 0.5f || radius < 0.0f || radius > shortest * 0.5f + 0.01f || bezel < 0.0f || glassThickness < 0.0f || refractiveIndex < 1.0f || refractiveIndex > 3.2f || refractionScale < 0.0f || refractionScale > 3.0f || displacementCap < 0.0f || pointScale < 0.5f || pointScale > 4.0f || rendererScale < 0.5f || rendererScale > 4.0f) return out;)
LGBO_STMT(float localX = x - centerX;)
LGBO_STMT(float localY = y - centerY;)
LGBO_STMT(float d = LGBOButtonRoundedBoxSDF(localX, localY, width, height, radius);)
LGBO_STMT(if (!isfinite(d)) return out;)
LGBO_STMT(out.signedDistance = d;)
LGBO_STMT(out.valid = true;)
LGBO_STMT(out.sampleU = LGBOClamp(x, 0.5f, width - 0.5f) / width;)
LGBO_STMT(out.sampleV = LGBOClamp(y, 0.5f, height - 0.5f) / height;)
LGBO_STMT(out.environmentU = out.sampleU;)
LGBO_STMT(out.environmentV = out.sampleV;)
LGBO_STMT(if (d >= 0.0f || !enabled || glassThickness <= 0.0f || refractionScale <= 0.0f || displacementCap <= 0.0f || refractiveIndex <= 1.0f) return out;)
LGBO_STMT(float depth = -d;)
LGBO_STMT(float depthRadius = shortest * 0.5f;)
LGBO_STMT(float t = LGBOClamp(depth / depthRadius, 0.0f, 1.0f);)
/* Finite spherical cap: aperture R and base-plane offset B determine
 * Rc=sqrt(R^2+B^2), sag=Rc-B. Reuse the existing bezel as B, not an
 * unconstrained new strength. Rationalized expressions remain stable at
 * very thin/corner cases. Pressure retains its original thickness ratio. */
LGBO_STMT(float rimHeight = LGBOMax(bezel, pointScale * 1.5f);)
LGBO_STMT(float curvatureRadius = LGBOHypot(depthRadius, rimHeight);)
LGBO_STMT(float capSag = depthRadius * depthRadius / (curvatureRadius + rimHeight);)
LGBO_STMT(float surfaceRoot = sqrt(rimHeight * rimHeight + depthRadius * depthRadius * t * (2.0f - t));)
LGBO_STMT(float capRise = depthRadius * depthRadius * t * (2.0f - t) / (surfaceRoot + rimHeight);)
LGBO_STMT(float normalizedHeight = capRise / capSag;)
LGBO_STMT(float heightAmplitude = LGBOMin(depthRadius, glassThickness) * (capSag / depthRadius);)
LGBO_STMT(out.height = heightAmplitude * normalizedHeight;)
/* Close only the outer 1.5pt footprint. At d=b the original finite-cap
 * height and slope are the matching data; the cubic starts tangent to zero
 * height outside the footprint and is monotone for q=b*m_b/h_b in [0,1]. */
LGBO_STMT(float lipWidth = LGBOMin(pointScale * 1.5f, depthRadius);)
LGBO_STMT(float lipT = lipWidth / depthRadius;)
LGBO_STMT(float lipSurfaceRoot = sqrt(rimHeight * rimHeight + depthRadius * depthRadius * lipT * (2.0f - lipT));)
LGBO_STMT(float lipCapRise = depthRadius * depthRadius * lipT * (2.0f - lipT) / (lipSurfaceRoot + rimHeight);)
LGBO_STMT(float lipCapHeight = heightAmplitude * (lipCapRise / capSag);)
LGBO_STMT(float lipCapDerivative = heightAmplitude * depthRadius * (1.0f - lipT) / (lipSurfaceRoot * capSag);)
LGBO_STMT(float gx = LGBOButtonRoundedBoxSDF(localX + 0.5f, localY, width, height, radius) - LGBOButtonRoundedBoxSDF(localX - 0.5f, localY, width, height, radius);)
LGBO_STMT(float gy = LGBOButtonRoundedBoxSDF(localX, localY + 0.5f, width, height, radius) - LGBOButtonRoundedBoxSDF(localX, localY - 0.5f, width, height, radius);)
LGBO_STMT(float gradientLength = LGBOHypot(gx, gy);)
LGBO_STMT(float outwardX = gradientLength > 0.0001f ? gx / gradientLength : 0.0f;)
LGBO_STMT(float outwardY = gradientLength > 0.0001f ? gy / gradientLength : 0.0f;)
LGBO_STMT(float normalizedHeightDerivative = t < 1.0f ? depthRadius * (1.0f - t) / (surfaceRoot * capSag) : 0.0f;)
LGBO_STMT(float heightDerivative = heightAmplitude * normalizedHeightDerivative;)
LGBO_STMT(float lipQ = lipCapHeight > 0.0f ? LGBOClamp(lipWidth * lipCapDerivative / lipCapHeight, 0.0f, 1.0f) : 0.0f;)
LGBO_STMT(if (depth < lipWidth) {)
LGBO_STMT(float lipU = depth / lipWidth;)
LGBO_STMT(float lipU2 = lipU * lipU;)
LGBO_STMT(float lipU3 = lipU2 * lipU;)
LGBO_STMT(out.height = lipCapHeight * ((3.0f - lipQ) * lipU2 + (lipQ - 2.0f) * lipU3);)
LGBO_STMT(heightDerivative = (lipCapHeight / lipWidth) * (2.0f * (3.0f - lipQ) * lipU + 3.0f * (lipQ - 2.0f) * lipU2);)
LGBO_STMT(})
LGBO_STMT(float normalX = heightDerivative * outwardX;)
LGBO_STMT(float normalY = heightDerivative * outwardY;)
LGBO_STMT(float normalZ = 1.0f;)
LGBO_STMT(bool contactInputValid = contactEnabled && isfinite(contactX) && isfinite(contactY) && isfinite(contactPressure);)
LGBO_STMT(if (contactInputValid && contactPressure > 0.0f) {)
LGBO_STMT(float boundedContactX = LGBOClamp(contactX, 0.0f, 1.0f);)
LGBO_STMT(float boundedContactY = LGBOClamp(contactY, 0.0f, 1.0f);)
LGBO_STMT(float boundedContactPressure = LGBOClamp(contactPressure, 0.0f, 1.0f);)
LGBO_STMT(float contactDx = x - boundedContactX * width;)
LGBO_STMT(float contactDy = y - boundedContactY * height;)
LGBO_STMT(float contactRadius = pointScale * 7.0f;)
LGBO_STMT(float contactRadiusSquared = contactRadius * contactRadius;)
LGBO_STMT(float contactDistanceSquared = contactDx * contactDx + contactDy * contactDy;)
LGBO_STMT(float contactQ = contactDistanceSquared / contactRadiusSquared;)
LGBO_STMT(float contactDepth = -d;)
LGBO_STMT(float contactFadeWidth = pointScale * 1.5f;)
LGBO_STMT(float contactFadeT = LGBOClamp(contactDepth / contactFadeWidth, 0.0f, 1.0f);)
LGBO_STMT(float contactEdgeFade = contactFadeT * contactFadeT * (3.0f - 2.0f * contactFadeT);)
LGBO_STMT(float contactEdgeFadeDerivative = (contactFadeT > 0.0f && contactFadeT < 1.0f) ? 6.0f * contactFadeT * (1.0f - contactFadeT) / contactFadeWidth : 0.0f;)
LGBO_STMT(if (contactQ < 1.0f && boundedContactPressure > 0.0f) {)
LGBO_STMT(float contactShapeBase = 1.0f - contactQ;)
LGBO_STMT(float contactShape = contactShapeBase * contactShapeBase * contactShapeBase;)
LGBO_STMT(float contactShapeGradientX = -6.0f * contactDx / contactRadiusSquared * contactShapeBase * contactShapeBase;)
LGBO_STMT(float contactShapeGradientY = -6.0f * contactDy / contactRadiusSquared * contactShapeBase * contactShapeBase;)
LGBO_STMT(float contactAmplitude = LGBOMin(1.15f * pointScale, heightAmplitude * 0.20f) * boundedContactPressure;)
LGBO_STMT(float contactHeightDelta = -contactAmplitude * contactShape * contactEdgeFade;)
LGBO_STMT(float contactDepthGradientX = -outwardX;)
LGBO_STMT(float contactDepthGradientY = -outwardY;)
LGBO_STMT(float contactGradientX = -contactAmplitude * (contactShapeGradientX * contactEdgeFade + contactShape * contactEdgeFadeDerivative * contactDepthGradientX);)
LGBO_STMT(float contactGradientY = -contactAmplitude * (contactShapeGradientY * contactEdgeFade + contactShape * contactEdgeFadeDerivative * contactDepthGradientY);)
/* A shallow surface cannot support the old additive dent near its thin lip.
 * Let D be the requested nonnegative dent and h the actual local height.
 * h_new=h^2/(h+D) stays nonnegative; use its exact chain-rule gradient.
 * At D=0 this is identity, and both geometry and normal vary continuously. */
LGBO_STMT(float contactBaseHeight = LGBOMax(out.height, 0.0f);)
LGBO_STMT(float contactRequestedDent = -contactHeightDelta;)
LGBO_STMT(float contactDenominator = contactBaseHeight + contactRequestedDent;)
LGBO_STMT(float contactHeightRatio = contactDenominator > 0.0f ? contactBaseHeight / contactDenominator : 1.0f;)
LGBO_STMT(float contactBaseGradientFactor = (1.0f - contactHeightRatio) * (1.0f - contactHeightRatio);)
LGBO_STMT(float contactDentGradientFactor = contactHeightRatio * contactHeightRatio;)
LGBO_STMT(contactGradientX = contactBaseGradientFactor * normalX + contactDentGradientFactor * contactGradientX;)
LGBO_STMT(contactGradientY = contactBaseGradientFactor * normalY + contactDentGradientFactor * contactGradientY;)
LGBO_STMT(if (isfinite(contactHeightRatio) && isfinite(contactGradientX) && isfinite(contactGradientY)) { out.height = contactBaseHeight * contactHeightRatio; normalX -= contactGradientX; normalY -= contactGradientY; })
LGBO_STMT(})
LGBO_STMT(})
LGBO_STMT(float normalLength = LGBOHypot(LGBOHypot(normalX, normalY), normalZ);)
LGBO_STMT(normalX /= normalLength;)
LGBO_STMT(normalY /= normalLength;)
LGBO_STMT(normalZ /= normalLength;)
LGBO_STMT(out.normalX = normalX;)
LGBO_STMT(out.normalY = normalY;)
LGBO_STMT(float eta = 1.0f / refractiveIndex;)
LGBO_STMT(float k = LGBOMax(0.0f, 1.0f - eta * eta * (1.0f - normalZ * normalZ));)
LGBO_STMT(float rootK = sqrt(k);)
LGBO_STMT(float rayFactor = eta * normalZ - rootK;)
LGBO_STMT(float rayX = rayFactor * normalX;)
LGBO_STMT(float rayY = rayFactor * normalY;)
LGBO_STMT(float rayZ = -eta + eta * normalZ * normalZ - rootK * normalZ;)
/* A ray at this surface point crosses this local height, not the maximum
 * dome height everywhere. Use the existing C1 finite path budget, then the
 * unchanged displacement budget; contact changes the very same local height. */
LGBO_STMT(float pathLength = LGBOSmoothCappedLength(LGBOMax(out.height, 0.0f), displacementCap);)
/* On the exact44pt button, the inherited16pt bezel suppressed refraction
 * through most of the22pt radius. Keep bezel as a maximum budget, but make the
 * actual optical shoulder proportional to radius, never a painted rim/light. */
LGBO_STMT(float radialEdgeDepth = LGBOMax(pointScale * 1.5f, depthRadius * 0.3f);)
LGBO_STMT(float effectiveEdgeDepth = LGBOMin(LGBOMax(bezel, 1.0f), radialEdgeDepth);)
LGBO_STMT(float edgeT = LGBOClamp(depth / effectiveEdgeDepth, 0.0f, 1.0f);)
LGBO_STMT(float edgeFade = edgeT * edgeT * (3.0f - 2.0f * edgeT);)
LGBO_STMT(float denominator = LGBOMax(-rayZ, 0.25f);)
LGBO_STMT(float offsetX = rayX / denominator * pathLength * refractionScale * edgeFade;)
LGBO_STMT(float offsetY = rayY / denominator * pathLength * refractionScale * edgeFade;)
LGBO_STMT(float offsetLength = LGBOHypot(offsetX, offsetY);)
LGBO_STMT(if (!isfinite(offsetLength)) { out.valid = false; return out; })
LGBO_STMT(float limitedOffsetLength = LGBOSmoothCappedLength(offsetLength, displacementCap);)
LGBO_STMT(if (offsetLength > 0.0f) { float factor = limitedOffsetLength / offsetLength; offsetX *= factor; offsetY *= factor; })
LGBO_STMT(out.offsetX = offsetX;)
LGBO_STMT(out.offsetY = offsetY;)
LGBO_STMT(out.sampleU = LGBOClamp(x + offsetX, 0.5f, width - 0.5f) / width;)
LGBO_STMT(out.sampleV = LGBOClamp(y + offsetY, 0.5f, height - 0.5f) / height;)
/* This owned source describes one plane. Without a separately measured
 * reflected environment or a traced second interface, compositing a second
 * differently displaced copy creates an ungrounded double image. Retain all
 * legacy result fields/ABI but make them coincide with the sole transmitted
 * ray and give the absent secondary path exactly zero energy. */
LGBO_STMT(out.environmentWeight = 0.0f;)
LGBO_STMT(out.environmentOffsetX = out.offsetX;)
LGBO_STMT(out.environmentOffsetY = out.offsetY;)
LGBO_STMT(out.environmentU = out.sampleU;)
LGBO_STMT(out.environmentV = out.sampleV;)
LGBO_STMT(return out;)
LGBO_FUNCTION_END

/* Preserve the frozen no-contact API for the existing Backboard path and
 * legacy tests. The local renderer opts into the extended shared function. */
LGBO_FUNCTION_BEGIN(LGButtonOpticsResult, LGButtonOpticsEvaluate, (float x, float y, float width, float height, float centerX, float centerY, float radius, float bezel, float glassThickness, float refractiveIndex, float refractionScale, float displacementCap, float pointScale, float rendererScale, bool enabled))
LGBO_STMT(return LGButtonOpticsEvaluateWithContact(x, y, width, height, centerX, centerY, radius, bezel, glassThickness, refractiveIndex, refractionScale, displacementCap, pointScale, rendererScale, enabled, false, 0.0f, 0.0f, 0.0f);)
LGBO_FUNCTION_END

/* Exact scalar dielectric coefficient. This supplies only an angular factor;
 * the optional color cue below still has no measured reflection environment. */
LGBO_FUNCTION_BEGIN(float, LGBODielectricFresnel, (float cosineIncident, float index))
LGBO_STMT(if (!isfinite(cosineIncident) || !isfinite(index) || index <= 1.0f || index > 3.2f) return 0.0f;)
LGBO_STMT(float ci = LGBOClamp(cosineIncident, 0.0f, 1.0f);)
LGBO_STMT(float ct = sqrt(LGBOMax(0.0f, 1.0f - (1.0f - ci * ci) / (index * index)));)
LGBO_STMT(float rs = (ci - index * ct) / (ci + index * ct);)
LGBO_STMT(float rp = (index * ci - ct) / (index * ci + ct);)
LGBO_STMT(return LGBOClamp(0.5f * (rs * rs + rp * rp), 0.0f, 1.0f);)
LGBO_FUNCTION_END

/* Same leased-source approximation as the parent, different angular weight.
 * Flat normal has no angular excess; there is no new light, tint or gain.
 * Remove the independent edgeBand that masked an already closed geometric
 * lip. The actual normal controls angular decay and the original local-height
 * coverage closes the zero-thickness contour. Thick tilted interior may have
 * a weak response: measure spatial support rather than calling this compact. */
LGBO_FUNCTION_BEGIN(float, LGBOImageEdgeRadianceWeight, (LGButtonOpticsResult q, float width, float height, float bezel, float pointScale, float refractiveIndex, bool enabled, bool leasedOverscan))
LGBO_STMT(if (!q.valid || !enabled || !leasedOverscan || !isfinite(width) || !isfinite(height) || !isfinite(bezel) || !isfinite(pointScale) || !isfinite(refractiveIndex) || !isfinite(q.signedDistance) || !isfinite(q.height) || !isfinite(q.normalX) || !isfinite(q.normalY) || q.signedDistance >= 0.0f || q.height <= 0.0f || width < 1.0f || width > 16384.0f || height < 1.0f || height > 16384.0f || pointScale < 0.5f || pointScale > 4.0f || refractiveIndex <= 1.0f || refractiveIndex > 3.2f) return 0.0f;)
LGBO_STMT(float lipWidth = LGBOMin(pointScale * 1.5f, LGBOMin(width, height) * 0.5f);)
LGBO_STMT(if (lipWidth <= 0.0f) return 0.0f;)
LGBO_STMT(float normalXY2 = LGBOClamp(q.normalX * q.normalX + q.normalY * q.normalY, 0.0f, 1.0f);)
LGBO_STMT(float cosineIncident = sqrt(LGBOMax(0.0f, 1.0f - normalXY2));)
LGBO_STMT(float f0 = LGBODielectricFresnel(1.0f, refractiveIndex);)
LGBO_STMT(float angularExcess = LGBOMax(0.0f, LGBODielectricFresnel(cosineIncident, refractiveIndex) - f0);)
LGBO_STMT(float thicknessT = LGBOClamp(q.height / lipWidth, 0.0f, 1.0f);)
LGBO_STMT(float thicknessCoverage = thicknessT * thicknessT * (3.0f - 2.0f * thicknessT);)
LGBO_STMT(float weight = angularExcess * thicknessCoverage;)
LGBO_STMT(if (!isfinite(weight)) return 0.0f;)
LGBO_STMT(return LGBOClamp(weight, 0.0f, 0.28f);)
LGBO_FUNCTION_END

/* Explicit image-space cone width, not a physical world-space reflection
 * distance: 12-degree half-angle times local cap height, capped at the legal
 * 16-point source overscan. The real leased source is sampled by the caller. */
LGBO_FUNCTION_BEGIN(float, LGBOImageEdgeRadianceRadius, (float localHeight, float pointScale))
LGBO_STMT(if (!isfinite(localHeight) || !isfinite(pointScale) || pointScale <= 0.0f) return 0.0f;)
LGBO_STMT(float screenConeTangent = 0.21255656f;)
LGBO_STMT(float requestedRadius = LGBOMax(localHeight, 0.0f) * screenConeTangent;)
LGBO_STMT(float legalRadius = 16.0f * pointScale;)
LGBO_STMT(return LGBOSmoothCappedLength(requestedRadius, legalRadius);)
LGBO_FUNCTION_END

/* Four equal, nonnegative quadrature weights preserve a constant source and
 * make the cone integral a convex average of actual captured radiance. */
LGBO_FUNCTION_BEGIN(float, LGBOAverageFourRadianceSamples, (float a, float b, float c, float d))
LGBO_STMT(return 0.25f * (a + b + c + d);)
LGBO_FUNCTION_END

/* Mix an optional same-live-source low-frequency edge integral in native Metal
 * space. It is a bounded image-driven cue, not external reflected radiance.
 * Preserve premultiplication and transmitted alpha; _sRGB samples are linear. */
LGBO_FUNCTION_BEGIN(float, LGBOEnvironmentMixPremultipliedChannel, (float transmittedPremul, float transmittedAlpha, float environmentPremul, float environmentAlpha, float weight))
LGBO_STMT(float alpha = LGBOClamp(transmittedAlpha, 0.0f, 1.0f);)
LGBO_STMT(if (alpha <= 0.00001f) return 0.0f;)
LGBO_STMT(float transmittedStraight = LGBOClamp(transmittedPremul / alpha, 0.0f, 1.0f);)
LGBO_STMT(float pathAlpha = LGBOClamp(environmentAlpha, 0.0f, 1.0f);)
LGBO_STMT(float pathStraight = pathAlpha > 0.00001f ? LGBOClamp(environmentPremul / pathAlpha, 0.0f, 1.0f) : transmittedStraight;)
LGBO_STMT(float boundedWeight = LGBOClamp(weight, 0.0f, 0.28f);)
LGBO_STMT(float straightResult = transmittedStraight + (pathStraight - transmittedStraight) * boundedWeight;)
LGBO_STMT(return LGBOClamp(straightResult, 0.0f, 1.0f) * alpha;)
LGBO_FUNCTION_END
