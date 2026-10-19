/* Bounded source-space footprint. C and generated MSL share this code.
 * The four offsets use the unique symmetric PSD square root of the excess
 * covariance, not an arbitrary principal-axis direction or a hard2/4tap split.
 * Existing optical height/normal/profile and texture leases are untouched.
 */
LGBO_STRUCT_BEGIN(LGMinificationFootprint)
LGBO_FIELD(float, major)
LGBO_FIELD(float, minor)
LGBO_FIELD(float, filterWidth)
LGBO_FIELD(float, kernelXX)
LGBO_FIELD(float, kernelXY)
LGBO_FIELD(float, kernelYY)
LGBO_FIELD(int, tapCount)
LGBO_FIELD(bool, valid)
LGBO_STRUCT_END(LGMinificationFootprint)

LGBO_FUNCTION_BEGIN(float, LGBOMinificationExcess, (float singularValue))
LGBO_STMT(float q=LGBOClamp((singularValue-1.0f)*4.0f,0.0f,1.0f);)
LGBO_STMT(float activation=q*q*(3.0f-2.0f*q);)
LGBO_STMT(float support=LGBOClamp(singularValue,1.0f,4.0f);)
LGBO_STMT(return (support*support-1.0f)*activation*activation;)
LGBO_FUNCTION_END

LGBO_FUNCTION_BEGIN(LGMinificationFootprint, LGBOAnalyzeMinificationFootprint, (float dxX, float dxY, float dyX, float dyY))
LGBO_STMT(LGMinificationFootprint out;)
LGBO_STMT(out.major=1.0f; out.minor=1.0f; out.filterWidth=1.0f;)
LGBO_STMT(out.kernelXX=0.0f; out.kernelXY=0.0f; out.kernelYY=0.0f;)
LGBO_STMT(out.tapCount=1; out.valid=false;)
LGBO_STMT(if (!isfinite(dxX)||!isfinite(dxY)||!isfinite(dyX)||!isfinite(dyY)) return out;)
LGBO_STMT(float c00=dxX*dxX+dyX*dyX;)
LGBO_STMT(float c01=dxX*dxY+dyX*dyY;)
LGBO_STMT(float c11=dxY*dxY+dyY*dyY;)
LGBO_STMT(float trace=c00+c11;)
LGBO_STMT(if (!isfinite(c00)||!isfinite(c01)||!isfinite(c11)||!isfinite(trace)) return out;)
LGBO_STMT(float delta=c00-c11;)
LGBO_STMT(float discScale=LGBOMax(fabs(delta),2.0f*fabs(c01));)
LGBO_STMT(float discriminant=0.0f;)
LGBO_STMT(if (discScale>0.0f) { float a=delta/discScale; float b=2.0f*c01/discScale; discriminant=discScale*sqrt(a*a+b*b); })
LGBO_STMT(float lambdaMajor=LGBOMax(0.0f,0.5f*(trace+discriminant));)
LGBO_STMT(float lambdaMinor=LGBOClamp(0.5f*(trace-discriminant),0.0f,lambdaMajor);)
LGBO_STMT(float major=sqrt(lambdaMajor); float minor=sqrt(lambdaMinor);)
LGBO_STMT(if (!isfinite(major)||!isfinite(minor)) return out;)
LGBO_STMT(out.major=major; out.minor=minor; out.filterWidth=LGBOClamp(major,1.0f,4.0f); out.valid=true;)
LGBO_STMT(if (major<=1.0f) return out;)
LGBO_STMT(float eMajor=LGBOMinificationExcess(major); float eMinor=LGBOMinificationExcess(minor);)
LGBO_STMT(float spectralSlope=(eMajor-eMinor)/LGBOMax(discriminant,1.0e-20f);)
LGBO_STMT(float e00=LGBOMax(0.0f,eMinor+spectralSlope*(c00-lambdaMinor));)
LGBO_STMT(float e01=spectralSlope*c01;)
LGBO_STMT(float e11=LGBOMax(0.0f,eMinor+spectralSlope*(c11-lambdaMinor));)
LGBO_STMT(float rootDet=sqrt(LGBOMax(0.0f,e00*e11-e01*e01));)
LGBO_STMT(float divisor=sqrt(LGBOMax(0.0f,e00+e11+2.0f*rootDet));)
LGBO_STMT(if (!isfinite(divisor)||divisor<=1.0e-12f) return out;)
/* Four equal-weight centered points (+/-3,+/-1), (+/-1,-/+3)
 * times sqrt(E)/sqrt(60) have second moment E/12, matching the bounded
 * additional source-footprint covariance beyond the unchanged linear sample.
 * Max tap-center radius sqrt(2.5) texels; all physical edges clamp per tap.
 */
LGBO_STMT(float gain=0.12909944487358055f/divisor;)
LGBO_STMT(out.kernelXX=(e00+rootDet)*gain;)
LGBO_STMT(out.kernelXY=e01*gain;)
LGBO_STMT(out.kernelYY=(e11+rootDet)*gain;)
LGBO_STMT(out.tapCount=4;)
LGBO_STMT(return out;)
LGBO_FUNCTION_END
