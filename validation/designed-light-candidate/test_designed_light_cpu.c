#include "LGButtonMaterialCandidate.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
static LGButtonOpticsResult eval(float x,float y,float p){return LGButtonOpticsEvaluateWithContact(x,y,132,132,66,66,66,48,p>0?52.8f:108,1.6f,p>0?1.8f:2,132*7.0f/36,3,3,true,p>0,.94f,.5f,p);}
int main(void){
 assert(fabsf(LGDesignedDielectricFresnel(.5f,1.5f)-.08918671f)<2e-7f);
 LGButtonOpticsResult flat=eval(66,66,0);assert(LGDesignedSoftboxCoefficient(flat,1.6f,3,1)==0);
 unsigned active=0,changed=0;
 for(int y=0;y<132;y++)for(int x=0;x<132;x++){
  LGButtonOpticsResult q=eval(x+.5f,y+.5f,0),p=eval(x+.5f,y+.5f,1);
  float a=LGDesignedSoftboxCoefficient(q,1.6f,3,1),b=LGDesignedSoftboxCoefficient(p,1.6f,3,1);
  assert(isfinite(a)&&a>=0&&a<=1&&isfinite(b)&&b>=0&&b<=1);
  assert(LGDesignedSoftboxCoefficient(q,1.6f,3,0)==0);
  assert(LGDesignedSoftboxCoefficient(q,1.6f,3,NAN)==0);
  assert(LGDesignedSoftboxCoefficient(q,1,3,1)==0);
  if(q.signedDistance>=0)assert(a==0);
  active+=a>.0001f;changed+=fabsf(a-b)>.001f;
  const float alpha[4]={0,64.0f/255,128.0f/255,1};
  for(unsigned i=0;i<4;i++){
   float c=alpha[i]*.2f;float v=LGDesignedSoftboxPremultipliedChannel(c,alpha[i],a);
   assert(isfinite(v)&&v>=c-1e-7f&&v<=alpha[i]+1e-7f);
   assert(LGDesignedSoftboxPremultipliedChannel(c,alpha[i],0)==c);
   assert(LGDesignedSoftboxPremultipliedChannel(alpha[i],alpha[i],a)==alpha[i]);
  }
 }
 assert(active>20&&active<132*132/5);assert(changed>10);
 // Same radial depth on lower/right surface must not create a symmetric ring.
 assert(LGDesignedSoftboxCoefficient(eval(130,66,0),1.6f,3,1)==0);
 assert(LGDesignedSoftboxCoefficient(eval(66,130,0),1.6f,3,1)==0);
 printf("PASS explicit design illumination only: active%u/17424, pressureChanged%u, direction-selective non-ring and off identity; not measured environment\n",active,changed);return 0;
}
