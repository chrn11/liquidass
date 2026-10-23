#include "LGCAClosedProfilePolicy.h"
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
static void need(bool b,const char *message){if(!b){fprintf(stderr,"FAIL %s\n",message);exit(1);}}
int main(void) {
 for(unsigned m=0;m<64;m++) need(LGCAClosedProfileMayUse(m&1,m&2,m&4,m&8,81,81,m&16,m&32,132,132,132,132,3)==(m==63),"all explicit original gates required");
 uint32_t formats[]={0,1,70,80,81,115};unsigned accepted=0;
 for(unsigned i=0;i<6;i++)for(unsigned j=0;j<6;j++) {bool b=LGCAClosedProfileMayUse(true,true,true,true,formats[i],formats[j],true,true,132,132,132,132,3);need(b==(formats[i]==81&&formats[j]==81),"only exact source81 + destination81");accepted+=b;}
 need(accepted==1,"one exact sRGB pair");
 need(!LGCAClosedProfileMayUse(true,true,true,true,81,81,true,true,NAN,132,132,132,3),"nonfinite geometry rejected");
 need(!LGCAClosedProfileMayUse(true,true,true,true,81,81,true,true,132,132,135,132,3),"destination beyond original2pixel bound rejected");
 puts("PASS CA profile host policy64 combinations,36format pairs and invalidgeometry; no GPU/runtime inferred");return 0;
}
