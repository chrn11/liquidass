/* Explicitly DESIGN illumination, not a source-capture or measured environment.
 * One neutral softbox is fixed in view space. Its finite angular aperture,
 * rather than an SDF stroke, selects the same actual surface normals. The
 * direction is20degrees behind the image plane, upper-left in screen axes.
 * These parameters are a declared UI design choice, not reconstructed lights. */
LGBO_FUNCTION_BEGIN(float, LGDesignedDielectricFresnel, (float ci, float index))
LGBO_STMT(if (!isfinite(ci) || !isfinite(index) || index<=1.0f || index>3.2f) return 0.0f;)
LGBO_STMT(ci=LGBOClamp(ci,0.0f,1.0f);)
LGBO_STMT(float ct=sqrt(LGBOMax(0.0f,1.0f-(1.0f-ci*ci)/(index*index)));)
LGBO_STMT(float rs=(ci-index*ct)/(ci+index*ct);)
LGBO_STMT(float rp=(index*ci-ct)/(index*ci+ct);)
LGBO_STMT(return LGBOClamp(0.5f*(rs*rs+rp*rp),0.0f,1.0f);)
LGBO_FUNCTION_END

LGBO_FUNCTION_BEGIN(float, LGDesignedSoftboxCoefficient, (LGButtonOpticsResult q, float index, float pointScale, float explicitStrength))
LGBO_STMT(if (!isfinite(explicitStrength) || explicitStrength<=0.0f || !q.valid || !isfinite(q.height) || q.height<=0.0f || !isfinite(q.signedDistance) || q.signedDistance>=0.0f || !isfinite(q.normalX) || !isfinite(q.normalY) || !isfinite(pointScale) || pointScale<0.5f || pointScale>4.0f || !isfinite(index) || index<=1.0f || index>3.2f) return 0.0f;)
LGBO_STMT(float nz=sqrt(LGBOClamp(1.0f-q.normalX*q.normalX-q.normalY*q.normalY,0.0f,1.0f));)
LGBO_STMT(float reflectedX=2.0f*nz*q.normalX;)
LGBO_STMT(float reflectedY=2.0f*nz*q.normalY;)
LGBO_STMT(float reflectedZ=2.0f*nz*nz-1.0f;)
/* Unit light-center vector at azimuth225deg/polar110deg; aperture28deg
 * outer,14deg inner, softstep interpolation. Fixed in view, NOT an outline. */
LGBO_STMT(float cosineAperture=-0.6644630244f*reflectedX-0.6644630244f*reflectedY-0.3420201433f*reflectedZ;)
LGBO_STMT(float apertureT=LGBOClamp((cosineAperture-0.8829475929f)/(0.9702957263f-0.8829475929f),0.0f,1.0f);)
LGBO_STMT(float aperture=apertureT*apertureT*(3.0f-2.0f*apertureT);)
LGBO_STMT(float heightT=LGBOClamp(q.height/(1.5f*pointScale),0.0f,1.0f);)
LGBO_STMT(float heightCoverage=heightT*heightT*(3.0f-2.0f*heightT);)
LGBO_STMT(float coefficient=LGDesignedDielectricFresnel(nz,index)*aperture*heightCoverage*LGBOClamp(explicitStrength,0.0f,1.0f);)
LGBO_STMT(return isfinite(coefficient)?LGBOClamp(coefficient,0.0f,1.0f):0.0f;)
LGBO_FUNCTION_END

/* Neutral unit-radiance design emitter. The resulting bounded convex
 * blend is a visual material approximation, NOT a full BRDF path integral.
 * Preserve the original transmitted alpha; zero gate returns original bits. */
LGBO_FUNCTION_BEGIN(float, LGDesignedSoftboxPremultipliedChannel, (float basePremul, float alpha, float coefficient))
LGBO_STMT(if (!isfinite(coefficient) || coefficient<=0.0f || !isfinite(alpha) || alpha<=0.0f) return basePremul;)
LGBO_STMT(float w=LGBOClamp(coefficient,0.0f,1.0f);)
LGBO_STMT(return basePremul+(alpha-basePremul)*w;)
LGBO_FUNCTION_END
