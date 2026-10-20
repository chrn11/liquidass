/* Run by macOS CI only; contracts and the exact shared mapping source. */
#include "LGLocalButtonUniforms.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static LGLocalButtonSourceContract make(float scale,int n) {
 LGLocalButtonSourceContract c={0};c.sourceRectInOwnerPoints=c.targetRectInOwnerPoints=CGRectMake(10,20,44,44);
 c.textureWidth=c.textureHeight=n;c.pointScale=scale;c.targetGeometryGeneration=1;return c;
}
int main(void){
 LGButtonOpticalState state={0};state.eligible=true;state.geometryGeneration=1;
 for(int n=131;n<=133;n++){
  LGLocalButtonSourceContract c=make(3,n);LGLocalButtonSourceLayout l={0};
  assert(LGLocalSourceLayoutForContract(&c,n,n,&l));assert(l.targetPixelWidth==(unsigned)n);
  LGLocalButtonUniforms plain={0},zero={0};assert(LGLocalButtonBuildUniforms(&c,&state,n,n,3,false,&plain));
  c.sourceOverscanEnabled=true;assert(LGLocalButtonBuildUniforms(&c,&state,n,n,3,false,&zero));
  assert(memcmp(&plain,&zero,sizeof plain)==0);assert(plain.resolution.x==n&&plain.radius==n*.5f&&plain.buttonSourceOverscanEnabled==0);
 }
 LGLocalButtonSourceContract c=make(3,228);c.sourceOverscanEnabled=true;
 c.sourceRectInOwnerPoints=CGRectMake(-6,4,76,76);LGLocalButtonSourceLayout l={0};assert(LGLocalSourceLayoutForContract(&c,228,228,&l));
 assert(l.targetPixelWidth==132&&l.leftPaddingPoints==16&&l.topPaddingPoints==16);
 LGLocalButtonUniforms u={0};assert(LGLocalButtonBuildUniforms(&c,&state,132,132,3,false,&u));assert(u.resolution.x==132&&u.buttonSourceTargetOriginPixels.x==48);
 assert(fabsf(u.buttonCandidateMaxOffset-132*7.0f/36.0f)<1e-5f);
 c.sourceOverscanEnabled=false;assert(!LGLocalSourceLayoutForContract(&c,228,228,&l));
 c.sourceOverscanEnabled=true;c.sourceRectInOwnerPoints.origin.x-=.0001;assert(!LGLocalSourceLayoutForContract(&c,228,228,&l));
 const double pads[]={.005,.01,.011};
 for(unsigned i=0;i<3;i++){
  c=make(3,132);c.sourceOverscanEnabled=true;c.sourceRectInOwnerPoints.origin.x-=pads[i];c.sourceRectInOwnerPoints.size.width+=pads[i];
  assert(!LGLocalSourceLayoutForContract(&c,132,132,&l)); // ambiguous source pixel extent rejected, not ignored
 }
 c=make(3,133);c.textureHeight=132;c.sourceOverscanEnabled=true;
 c.sourceRectInOwnerPoints.origin.x-=1.0/6.0;c.sourceRectInOwnerPoints.size.width+=1.0/3.0;
 assert(LGLocalSourceLayoutForContract(&c,133,132,&l)); // explicit fractional-pixel ROI with exact source extent
 assert(LGLocalButtonBuildUniforms(&c,&state,132,132,3,true,&u));assert(fabsf(u.buttonSourceTargetOriginPixels.x-.5f)<1e-5f);
 assert(fabsf(LGBOMapTargetUVToSource(.5f,132,133,.5f,true)-.5f)<1e-7f);
 c.sourceRectInOwnerPoints.origin.x=NAN;assert(!LGLocalSourceLayoutForContract(&c,133,132,&l));
 c=make(3,228);c.sourceOverscanEnabled=true;c.sourceRectInOwnerPoints=CGRectMake(-6,4,76,76);
 assert(!LGLocalSourceLayoutForContract(&c,227,228,&l));
 unsigned external=0;
 for(int y=0;y<132;y++)for(int x=0;x<132;x++){
  LGButtonOpticsResult a=LGButtonOpticsEvaluate(x+.5f,y+.5f,132,132,66,66,66,48,108,1.6f,2,132*7.0f/36,3,3,true);
  if(a.signedDistance>=0)continue;
  float px=x+.5f+a.environmentOffsetX,py=y+.5f+a.environmentOffsetY;
  float su=LGBOMapTargetUVToSource(px/132,132,228,48,true),sv=LGBOMapTargetUVToSource(py/132,132,228,48,true);
  assert(isfinite(su)&&isfinite(sv)&&su>=.5f/228&&su<=1-.5f/228&&sv>=.5f/228&&sv<=1-.5f/228);
  if(a.environmentWeight>.001f&&(px<0||px>=132||py<0||py>=132))external++;
 }
 assert(external>0);assert(LGBOMapTargetUVToSource(-1,132,228,48,true)==.5f/228);
 assert(LGBOMapTargetUVToSource(2,132,228,48,true)==1-.5f/228);
 assert(LGBOMapTargetUVToSource(-.3f,132,132,0,false)==-.3f);
 printf("PASS bounded overscan source/ROI/pixel-phase/legacy rounding; raw reflected mapping reaches outside target in %u interior pixels\n",external);return 0;
}
