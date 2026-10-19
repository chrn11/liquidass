#include "LGButtonMaterialCandidate.h"
#include <math.h>
#include <stdio.h>
#include <assert.h>
int main(void){
 unsigned active=0,outsideROI=0,outsideShape=0,reads=0;float maxW=0,maxR=0,minEdgeClearance=132;
 for(int y=0;y<132;y++)for(int x=0;x<132;x++){
  float px=x+.5f,py=y+.5f;
  LGButtonOpticsResult q=LGButtonOpticsEvaluateWithContact(px,py,132,132,66,66,66,48,108,1.6f,2,132*7.0f/36.0f,3,3,true,false,0,0,0);
  float w=LGBOImageEdgeRadianceWeight(q,132,132,48,3,1.6f,true,true);assert(isfinite(w)&&w>=0&&w<=.28f);if(w<=0)continue;
  active++;maxW=fmaxf(maxW,w);float n=LGBOHypot(q.normalX,q.normalY);float nx=n>.0001f?q.normalX/n:1,ny=n>.0001f?q.normalY/n:0;
  float r=LGBOImageEdgeRadianceRadius(q.height,3);maxR=fmaxf(maxR,r);float dx[4]={r*nx,-r*nx,-r*ny,r*ny},dy[4]={r*ny,-r*ny,r*nx,-r*nx};
  for(int k=0;k<4;k++){float sx=px+q.offsetX+dx[k],sy=py+q.offsetY+dy[k];reads++;if(sx<0||sx>132||sy<0||sy>132)outsideROI++;
   if(LGBOButtonRoundedBoxSDF(sx-66,sy-66,132,132,66)>=0)outsideShape++;
   minEdgeClearance=fminf(minEdgeClearance,fminf(fminf(sx,132-sx),fminf(sy,132-sy)));
  }
 }
 printf("{\"scope\":\"Exact compiled shared geometry and edge sample positions for default132px idle; not material pixels\",\"activePixels\":%u,\"tapPositions\":%u,\"tapPositionsOutsideROI\":%u,\"tapPositionsOutsideGlassShape\":%u,\"minimumROIPositionClearance\":%.9g,\"maxMixWeight\":%.9g,\"maxConeRadiusTexelsInActiveBand\":%.9g}\n",active,reads,outsideROI,outsideShape,minEdgeClearance,maxW,maxR);return 0;
}
