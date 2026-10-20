#include "LGLocalButtonRefreshPolicy.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
 assert(LGLocalIdleRefreshInterval()>=1.0/15.0 && LGLocalIdleRefreshInterval()<0.1);
 assert(LGLocalIdleRefreshShouldRun(true,true,true,true,true,false,false));
 for(unsigned i=0;i<5;i++) { bool v[5]={true,true,true,true,true};v[i]=false;
  assert(!LGLocalIdleRefreshShouldRun(v[0],v[1],v[2],v[3],v[4],false,false)); }
 assert(!LGLocalIdleRefreshShouldRun(true,true,true,true,true,true,false));
 assert(!LGLocalIdleRefreshShouldRun(true,true,true,true,true,false,true));
 unsigned failures=0;
 for(unsigned i=1;i<=3;i++){failures=LGLocalIdleRefreshFailureCount(failures,true);assert(failures==i);assert(LGLocalIdleRefreshMayRetry(failures)==(i<3));}
 assert(LGLocalIdleRefreshFailureCount(failures,true)==3);
 assert(LGLocalIdleRefreshFailureCount(failures,false)==0);
 assert(LGLocalStableCompletedAvailability(false,true));
 assert(LGLocalStableCompletedAvailability(true,false));
 assert(!LGLocalStableCompletedAvailability(false,false));
 assert(LGLocalRetainedCompletionFresh(10.075,10,true,true,true,true));
 assert(!LGLocalRetainedCompletionFresh(10.101,10,true,true,true,true));
 assert(!LGLocalRetainedCompletionFresh(10.01,10,false,true,true,true));
 assert(!LGLocalRetainedCompletionFresh(10.01,10,true,false,true,true));
 assert(!LGLocalRetainedCompletionFresh(10.01,10,true,true,false,true));
 assert(!LGLocalRetainedCompletionFresh(10.01,10,true,true,true,false));
 assert(!LGLocalRetainedCompletionFresh(NAN,10,true,true,true,true));
 puts("PASS bounded idle cadence, finite failure retry and actual completed-frame100ms policy (value-only, not runtime)");
 return 0;
}
