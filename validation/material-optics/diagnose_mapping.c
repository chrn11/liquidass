#include "LGButtonMaterialCandidate.h"
#include "LGButtonPressureRoute.h"
#include <stdio.h>
#include <math.h>
#include <assert.h>
static LGButtonOpticsResult at(float x,float y,unsigned phase){
 float thick=108,ref=2;
 if(phase){float factor=1;assert(LGButtonPressureMaterial(132,108,8,&thick,&factor));ref=2*factor;}
 return LGButtonOpticsEvaluateWithContact(x,y,132,132,66,66,66,48,thick,1.6f,ref,132*7.0f/36.0f,3,3,true,phase!=0,phase==1?.06f:.94f,.5f,phase?1:0);
}
static void pos(float x,float y,unsigned phase,unsigned path,float *a,float *b){
 LGButtonOpticsResult q=at(x,y,phase);
 *a=228*LGBOMapTargetUVToSource((x+(path?q.environmentOffsetX:q.offsetX))/132,132,228,48,true);
 *b=228*LGBOMapTargetUVToSource((y+(path?q.environmentOffsetY:q.offsetY))/132,132,228,48,true);
}
int main(void){
 puts("{\"scope\":\"C diagnostics of exact same shared formula and source mapping compiled on macOS, NOT material pixels or GPU timing\",\"target\":132,\"source\":228,\"origin\":[48,48],\"records\":[");
 for(unsigned phase=0;phase<3;phase++)for(unsigned path=0;path<2;path++){
  unsigned n=0,fold=0,over4=0,biaxial=0,nearEdge=0,edgeFold=0;float maxMajor=0,maxMinor=0,minDet=1e9f;double sumMajor=0;
  for(int y=0;y<132;y++)for(int x=0;x<132;x++){
   float px=x+.5f,py=y+.5f;LGButtonOpticsResult q=at(px,py,phase);if(!q.valid||q.signedDistance>=-.75f)continue;
   float xm,ym,xp,yp,ux,uy,vx,vy;
   pos(px-.5f,py,phase,path,&xm,&ym);pos(px+.5f,py,phase,path,&xp,&yp);float dxx=xp-xm,dxy=yp-ym;
   pos(px,py-.5f,phase,path,&ux,&uy);pos(px,py+.5f,phase,path,&vx,&vy);float dyx=vx-ux,dyy=vy-uy;
   LGMinificationFootprint fp=LGBOAnalyzeMinificationFootprint(dxx,dxy,dyx,dyy);assert(fp.valid);n++;
   float det=dxx*dyy-dxy*dyx;minDet=fminf(minDet,det);maxMajor=fmaxf(maxMajor,fp.major);maxMinor=fmaxf(maxMinor,fp.minor);sumMajor+=fp.major;
   if(det<0)fold++;if(fp.major>4)over4++;if(fp.minor>1.001f)biaxial++;
   if(q.signedDistance>-20){nearEdge++;if(det<0)edgeFold++;}
  }
  printf("{\"phase\":%u,\"path\":\"%s\",\"evaluatedInteriorPixels\":%u,\"negativeDeterminantPixels\":%u,\"majorOverBound4\":%u,\"bothAxesMinify\":%u,\"maxMajor\":%.9g,\"maxMinor\":%.9g,\"minimumDeterminant\":%.9g,\"meanMajor\":%.9g,\"nearEdgePixels\":%u,\"nearEdgeNegativeDet\":%u}%s\n",phase,path?"secondary":"primary",n,fold,over4,biaxial,maxMajor,maxMinor,minDet,sumMajor/n,nearEdge,edgeFold,phase==2&&path==1?"":",");
 }
 puts("]}");return 0;
}
