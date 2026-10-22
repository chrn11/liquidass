#include "LGButtonMaterialCandidate.h"
#include <assert.h>
#include <stdio.h>
#include <math.h>
static LGButtonOpticsResult eval(float x,float y){return LGButtonOpticsEvaluate(x,y,132,132,66,66,66,48,108,1.6f,2,132*7.0f/36.0f,3,3,true);}
int main(void){
 unsigned active=0,exterior=0,beyondROI=0;
 for(int y=0;y<132;y++)for(int x=0;x<132;x++){
  float px=x+.5f,py=y+.5f;LGButtonOpticsResult q=eval(px,py);
  float w=LGBOImageEdgeRadianceWeight(q,132,132,48,3,1.6f,true,true);
  assert(isfinite(w)&&w>=0&&w<=.28f);if(w==0)continue;active++;
  LGBOEdgeExteriorPatch p=LGBOBuildEdgeExteriorPatch(px,py,132,132,66,66,66,48,3);assert(p.valid&&p.support>0&&p.support<=48);
  assert(fabsf(LGBOButtonRoundedBoxSDF(p.boundaryX-66,p.boundaryY-66,132,132,66))<.0001f);
  float sx=0,sy=0;
  for(int k=0;k<4;k++){
   float a=LGBOExteriorPatchSampleX(p,k),b=LGBOExteriorPatchSampleY(p,k);sx+=a*.25f;sy+=b*.25f;
   assert(isfinite(a)&&isfinite(b)&&a>=-48+.5f&&a<=180-.5f&&b>=-48+.5f&&b<=180-.5f);
   float radial=(a-p.boundaryX)*p.outwardX+(b-p.boundaryY)*p.outwardY;
   assert(radial>=0&&radial<=p.support);
   if(LGBOButtonRoundedBoxSDF(a-66,b-66,132,132,66)>0)exterior++;
   if(a<0||a>132||b<0||b>132)beyondROI++;
  }
  assert(fabsf(sx-(p.boundaryX+.5f*p.support*p.outwardX))<.0001f);
  assert(fabsf(sy-(p.boundaryY+.5f*p.support*p.outwardY))<.0001f);
 }
 assert(active>100&&exterior==active*4&&beyondROI>100);
 // Finite exterior source at the lip must not create a nonzero contour step.
 float eps[4]={.1f,.01f,.001f,.0001f},prev=1;
 for(int k=0;k<4;k++){LGButtonOpticsResult q=eval(132-eps[k],66);float w=LGBOImageEdgeRadianceWeight(q,132,132,48,3,1.6f,true,true);assert(w<=prev&&w>=0);prev=w;}
 assert(prev<1e-8f);
 LGButtonOpticsResult q=eval(127,66);assert(LGBOImageEdgeRadianceWeight(q,132,132,48,3,1.6f,true,false)==0);
 assert(!LGBOBuildEdgeExteriorPatch(NAN,1,132,132,66,66,66,48,3).valid);
 assert(!LGBOBuildEdgeExteriorPatch(132,66,132,132,66,66,66,48,3).valid);
 // Actual bounds short of requested exterior coordinates are rejected by MSL;
 // geometry does not pretend to invent the missing pixel via edge repetition.
 LGBOEdgeExteriorPatch p=LGBOBuildEdgeExteriorPatch(130.5f,66,132,132,66,66,66,48,3);assert(p.valid);
 assert(LGBOExteriorPatchSampleX(p,2)>135.0f);
 puts("PASS shared exterior patch coordinates, finite source support, contour continuity and no-overscan gate; GPU must confirm actual pixels");return 0;
}
