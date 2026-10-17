/* One scalar coordinate transform compiled by C and stringified into MSL.
 * Input UV is target-local and may extend beyond its ROI only by the optical
 * model's bounded displacement. The FINAL clamp belongs to the real source.
 * Disabled returns input unchanged for exact historical pixel identity.
 */
LGBO_FUNCTION_BEGIN(float, LGBOMapTargetUVToSource, (float targetUV, float targetPixels, float sourcePixels, float originPixels, bool overscanEnabled))
LGBO_STMT(if (!overscanEnabled) return targetUV;)
LGBO_STMT(if (!isfinite(targetUV) || !isfinite(targetPixels) || !isfinite(sourcePixels) || !isfinite(originPixels) || targetPixels < 1.0f || sourcePixels < targetPixels || sourcePixels > 16384.0f || originPixels < 0.0f || originPixels + targetPixels > sourcePixels + 0.001f) return 0.0f;)
LGBO_STMT(float sourcePixel = originPixels + targetUV * targetPixels;)
LGBO_STMT(if (!isfinite(sourcePixel)) return 0.0f;)
LGBO_STMT(return LGBOClamp(sourcePixel, 0.5f, sourcePixels - 0.5f) / sourcePixels;)
LGBO_FUNCTION_END
