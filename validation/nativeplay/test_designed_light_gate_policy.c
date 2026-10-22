#include "LGDesignedLightExperimentPolicy.h"
#include <stdio.h>
#include <stdlib.h>
static void require(int v,const char *name) { if(!v) { fprintf(stderr,"FAIL %s\n",name); exit(1); } }
int main(void) {
    for(unsigned b=0;b<64;b++) {
        bool a=LGDLExperimentMayEnable((b&1)!=0,(b&2)!=0,(b&4)!=0,(b&8)!=0,(b&16)!=0,(b&32)!=0);
        require(a==(b==63),"only all six effective gate conditions may enable");
    }
    float bad[]={0.0f,-0.0f,-1.0f,0.99999994f,1.00000012f,NAN,INFINITY,-INFINITY};
    for(unsigned i=0;i<sizeof(bad)/sizeof(bad[0]);i++) require(!LGDLPrimaryStrengthIsOn(bad[i]),"invalid main primary strength cannot create auxiliary ON");
    require(LGDLPrimaryStrengthIsOn(1.0f),"exact main ON accepted");
    puts("PASS strict six-condition experiment gate64 cases and exact finite primary strength9 cases; value-policy only");
    return 0;
}
