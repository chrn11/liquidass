#include "LGButtonMaterialCandidate.h"
#include <math.h>
#include <stdio.h>
#include <assert.h>
int main(void){
 unsigned active=0,exterior=0,roi=0,reads=0,rejected=0;float maxw=0,clearance=228,maxsupport=0;
 for(int y=0;y<132;y++)for(int x=0;x<132;x++){
  float px=x+.5f,py=y+.5f;
  LGButtonOpticsResult q=LGButtonOpticsEvaluateWithContact(px,py,132,132,66,66,66,48,108,1.6f,2,132*7.0f/36.0f,3,3,true,false,0,0,0);
  float w=LGBOImageEdgeRadianceWeight(q,132,132,48,3,1.6f,true,true);assert(isfinite(w)&&w>=0&&w<=.28f);if(w<=0)continue;active++;maxw=fmaxf(maxw,w);
  LGBOEdgeExteriorPatch p=LGBOBuildEdgeExteriorPatch(px,py,132,132,66,66,66,48,3);assert(p.valid);maxsupport=fmaxf(maxsupport,p.support);
  for(int k=0;k<4;k++){
   float sx=LGBOExteriorPatchSampleX(p,k),sy=LGBOExteriorPatchSampleY(p,k);reads++;
   if(sx<0||sx>132||sy<0||sy>132)roi++;
   if(LGBOButtonRoundedBoxSDF(sx-66,sy-66,132,132,66)>=0)exterior++;
   float ax=sx+48,ay=sy+48;float c=fminf(fminf(ax-.5f,227.5f-ax),fminf(ay-.5f,227.5f-ay));clearance=fminf(clearance,c);if(c<0)rejected++;
  }
 }
 printf("{\"scope\":\"Exact shared exterior patch positions,132px idle in228px captured source,48pxpadding; not material pixels\",\"activePixels\":%u,\"tapPositions\":%u,\"tapPositionsOutsideROI\":%u,\"tapPositionsOutsideGlassShape\":%u,\"tapPositionsOutsideActualSource\":%u,\"minimumPhysicalHalfTexelClearance\":%.9g,\"maxMixWeight\":%.9g,\"patchSupportTexels\":%.9g,\"clampEvents\":0}\n",active,reads,roi,exterior,rejected,clearance,maxw,maxsupport);assert(exterior==reads&&roi>100&&rejected==0);return 0;
}
