/* Explicit exterior source-plane patch, not an environment-map inversion.
 * Closest rounded-box boundary + nonnegative outward support; four equal
 * Gauss nodes integrate a rectangular low-frequency neighborhood. The support
 * length reuses the bounded edge-band geometry, <=16pt. Final clamping to the
 * actual leased texture is still mandatory in MSL, not inferred source data. */
LGBO_STRUCT_BEGIN(LGBOEdgeExteriorPatch)
LGBO_FIELD(float, boundaryX)
LGBO_FIELD(float, boundaryY)
LGBO_FIELD(float, outwardX)
LGBO_FIELD(float, outwardY)
LGBO_FIELD(float, support)
LGBO_FIELD(bool, valid)
LGBO_STRUCT_END(LGBOEdgeExteriorPatch)

LGBO_FUNCTION_BEGIN(LGBOEdgeExteriorPatch, LGBOBuildEdgeExteriorPatch, (float x, float y, float width, float height, float centerX, float centerY, float radius, float bezel, float pointScale))
LGBO_STMT(LGBOEdgeExteriorPatch out;)
LGBO_STMT(out.boundaryX=0.0f; out.boundaryY=0.0f; out.outwardX=0.0f; out.outwardY=0.0f; out.support=0.0f; out.valid=false;)
LGBO_STMT(if (!isfinite(x) || !isfinite(y) || !isfinite(width) || !isfinite(height) || !isfinite(centerX) || !isfinite(centerY) || !isfinite(radius) || !isfinite(bezel) || !isfinite(pointScale) || width<1.0f || height<1.0f || width>16384.0f || height>16384.0f || radius<0.0f || bezel<=0.0f || pointScale<0.5f || pointScale>4.0f) return out;)
LGBO_STMT(float shortest=LGBOMin(width,height);)
LGBO_STMT(float r=LGBOClamp(radius,0.0f,shortest*0.5f);)
LGBO_STMT(float localX=x-centerX, localY=y-centerY;)
LGBO_STMT(float dx=LGBOAbs(localX)-(width*0.5f-r), dy=LGBOAbs(localY)-(height*0.5f-r);)
LGBO_STMT(float qx=LGBOMax(dx,0.0f), qy=LGBOMax(dy,0.0f);)
LGBO_STMT(float length=LGBOHypot(qx,qy);)
LGBO_STMT(float sx=localX<0.0f?-1.0f:1.0f, sy=localY<0.0f?-1.0f:1.0f;)
LGBO_STMT(if (length>0.000001f) { out.outwardX=sx*qx/length; out.outwardY=sy*qy/length; } else if (dx>dy) { out.outwardX=sx; } else { out.outwardY=sy; })
LGBO_STMT(float d=length+LGBOMin(LGBOMax(dx,dy),0.0f)-r;)
LGBO_STMT(if (!isfinite(d) || d>=0.0f) return out;)
LGBO_STMT(out.boundaryX=x-d*out.outwardX; out.boundaryY=y-d*out.outwardY;)
LGBO_STMT(out.support=LGBOMin(16.0f*pointScale,LGBOMin(LGBOMax(bezel,1.0f),LGBOMax(1.5f*pointScale,shortest*0.15f)));)
LGBO_STMT(out.valid=isfinite(out.boundaryX) && isfinite(out.boundaryY) && out.support>0.0f;)
LGBO_STMT(return out;)
LGBO_FUNCTION_END

LGBO_FUNCTION_BEGIN(float, LGBOExteriorPatchRadialNode, (int tap))
LGBO_STMT(return tap<2?0.2113248654051871f:0.7886751345948129f;)
LGBO_FUNCTION_END
LGBO_FUNCTION_BEGIN(float, LGBOExteriorPatchTangentNode, (int tap))
LGBO_STMT(return (tap==0 || tap==2)?-0.5773502691896258f:0.5773502691896258f;)
LGBO_FUNCTION_END
LGBO_FUNCTION_BEGIN(float, LGBOExteriorPatchSampleX, (LGBOEdgeExteriorPatch p, int tap))
LGBO_STMT(return p.boundaryX+p.support*(LGBOExteriorPatchRadialNode(tap)*p.outwardX-LGBOExteriorPatchTangentNode(tap)*p.outwardY);)
LGBO_FUNCTION_END
LGBO_FUNCTION_BEGIN(float, LGBOExteriorPatchSampleY, (LGBOEdgeExteriorPatch p, int tap))
LGBO_STMT(return p.boundaryY+p.support*(LGBOExteriorPatchRadialNode(tap)*p.outwardY+LGBOExteriorPatchTangentNode(tap)*p.outwardX);)
LGBO_FUNCTION_END
