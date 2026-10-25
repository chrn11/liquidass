#include "LGCAClosedProfilePolicy.h"
#include "LGCAClosedSourceAdmission.h"
#include <stdio.h>
#include <stdlib.h>
int main(void) {
    unsigned denied=0;
    for (unsigned bits=0;bits<256;bits++) {
        bool requested=(bits&1)!=0;
        bool wouldCreateNewRuntime=requested && LGCAClosedProductionSourceAdmitted() &&
            LGCAClosedProfileMayUse((bits&2)!=0,true,(bits&4)!=0,(bits&8)!=0,
                (bits&16)?81:80,(bits&32)?81:80,(bits&64)!=0,(bits&128)!=0,
                132,132,132,132,3);
        if (wouldCreateNewRuntime) { fputs("FAIL unintegrated CA producer was admitted\n",stderr); return 1; }
        denied++;
    }
    if (LGCAClosedProductionSourceAdmitted()) return 1;
    printf("PASS unintegrated production source denied for %u compile/request/format/identity combinations; no producer interface is pretended\n",denied);
    return 0;
}
