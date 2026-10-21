#include "LGButtonMaterialCandidate.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
static double oracle(double c,double n){
 double si2=fmax(0,1-c*c),t=sqrt(1-si2/(n*n));
 double rs=(c-n*t)/(c+n*t),rp=(n*c-t)/(n*c+t);return (rs*rs+rp*rp)/2;
}
static LGButtonOpticsResult q(float depth,float pressure){
 return LGButtonOpticsEvaluateWithContact(132-depth,66,132,132,66,66,66,48,pressure>0?52.8f:108,1.6f,pressure>0?1.8f:2,132*7.0f/36,3,3,true,pressure>0,.94f,.5f,pressure);
}
int main(void){
 const float ns[]={1.01f,1.3f,1.6f,2.1f,3.2f};
 for(unsigned j=0;j<5;j++)for(unsigned i=0;i<=100;i++){
  float c=i/100.0f,n=ns[j];float f=LGBODielectricFresnel(c,n);
  assert(isfinite(f)&&f>=0&&f<=1&&fabs(f-oracle(c,n))<5e-7);
 }
 assert(LGBODielectricFresnel(NAN,1.6f)==0&&LGBODielectricFresnel(1,NAN)==0);
 assert(LGBODielectricFresnel(.5f,1)==0);
 assert(fabsf(LGBODielectricFresnel(1,1.5f)-.04f)<1e-7f);
 assert(fabsf(LGBODielectricFresnel(.5f,1.5f)-.08918671f)<1e-7f);
 for(unsigned state=0;state<2;state++)for(unsigned i=0;i<=264;i++){
  float d=i*.25f;LGButtonOpticsResult s=q(d,state);float w=LGBOImageEdgeRadianceWeight(s,132,132,48,3,1.6f,true,true);
  float c=sqrtf(fmaxf(0,1-s.normalX*s.normalX-s.normalY*s.normalY));float f0=LGBODielectricFresnel(1,1.6f);
  float cov=fminf(1,fmaxf(0,s.height/4.5f));cov=cov*cov*(3-2*cov);
  double expected=fmin(.28,fmax(0,oracle(c,1.6f)-f0)*cov);
  assert(isfinite(w)&&w>=0&&w<=.28f&&fabs(w-expected)<1e-6);
  assert(LGBOImageEdgeRadianceWeight(s,132,132,48,3,1.6f,false,true)==0);
  assert(LGBOImageEdgeRadianceWeight(s,132,132,48,3,1.6f,true,false)==0);
 }
 assert(LGBOImageEdgeRadianceWeight(q(0,0),132,132,48,3,1.6f,true,true)==0);
 assert(LGBOImageEdgeRadianceWeight(q(66,0),132,132,48,3,1.6f,true,true)==0);
 LGButtonOpticsResult tiny=q(.001f,0);assert(LGBOImageEdgeRadianceWeight(tiny,132,132,48,3,1.6f,true,true)<1e-8f);
 for(unsigned i=0;i<3;i++){
  float depth=i==0?0.01f:(i==1?4.5f:2.881f),eps=.0001f;
  float a=LGBOImageEdgeRadianceWeight(q(depth-eps,0),132,132,48,3,1.6f,true,true);
  float b=LGBOImageEdgeRadianceWeight(q(depth+eps,0),132,132,48,3,1.6f,true,true);assert(fabsf(a-b)<1e-4f);
 }
 puts("PASS actual shared exact Fresnel vs double oracle; angular excess/zero/off/source domain boundaries; new weight not physical reflection evidence");return 0;
}
