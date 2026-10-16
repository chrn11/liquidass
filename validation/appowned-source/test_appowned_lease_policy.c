#include "LGAppOwnedLeasePolicy.h"
#include "LGLocalButtonSourceContract.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void test_slot_lease_epochs(void) {
    LGAppOwnedLeaseSlotValue s={0}; uint64_t e1=0,e2=0;
    assert(LGAppOwnedLeaseCanReserve(&s));
    assert(LGAppOwnedLeaseReserve(&s,7,&e1) && e1==1 && s.writing);
    assert(!LGAppOwnedLeaseAcquire(&s,7,e1));
    assert(LGAppOwnedLeasePublish(&s,7,e1) && s.leaseCount==1);
    assert(LGAppOwnedLeaseAcquire(&s,7,e1));
    assert(LGAppOwnedLeaseAcquire(&s,7,e1));
    assert(LGAppOwnedLeaseAcquire(&s,7,e1) && s.leaseCount==4);
    assert(!LGAppOwnedLeaseAcquire(&s,7,e1));
    assert(!LGAppOwnedLeaseCanReserve(&s));
    assert(!LGAppOwnedLeaseEnd(&s,8,e1) && s.leaseCount==4);
    assert(LGAppOwnedLeaseEnd(&s,7,e1));
    assert(LGAppOwnedLeaseEnd(&s,7,e1));
    assert(LGAppOwnedLeaseEnd(&s,7,e1));
    assert(LGAppOwnedLeaseEnd(&s,7,e1) && s.leaseCount==0);
    assert(LGAppOwnedLeaseReserve(&s,8,&e2) && e2==2);
    assert(LGAppOwnedLeasePublish(&s,8,e2) && s.leaseCount==1);
    assert(!LGAppOwnedLeaseEnd(&s,7,e1) && s.leaseCount==1);
    assert(LGAppOwnedLeaseEnd(&s,8,e2) && LGAppOwnedLeaseCanReserve(&s));
}

static void test_bounded_three_slot_ring(void) {
    LGAppOwnedLeaseSlotValue slots[LG_APP_OWNED_TEXTURE_SLOT_COUNT]={{0}};
    uint64_t epochs[LG_APP_OWNED_TEXTURE_SLOT_COUNT]={0};
    for (unsigned i=0;i<LG_APP_OWNED_TEXTURE_SLOT_COUNT;i++) {
        assert(LGAppOwnedLeaseReserve(&slots[i],1,&epochs[i]));
        assert(LGAppOwnedLeasePublish(&slots[i],1,epochs[i]));
    }
    for (unsigned i=0;i<LG_APP_OWNED_TEXTURE_SLOT_COUNT;i++)
        assert(!LGAppOwnedLeaseCanReserve(&slots[i]));
    assert(!LGAppOwnedLeaseReserve(&slots[0],2,&epochs[0]));
    assert(LGAppOwnedLeaseEnd(&slots[1],1,epochs[1]));
    assert(LGAppOwnedLeaseCanReserve(&slots[1]));
}

static void test_value_contract_uses_exact_opaque_domain(void) {
    LGLocalButtonSourceContract c; memset(&c,0,sizeof(c));
    c.sourceRectInOwnerPoints=CGRectMake(4,8,76,76);
    c.targetRectInOwnerPoints=CGRectMake(20,24,44,44);
    c.textureWidth=152; c.textureHeight=152; c.pixelFormat=81; c.pointScale=2;
    c.ownerInstanceToken=11; c.ownerGeneration=2; c.frameGeneration=3;
    c.targetGeometryGeneration=9; c.frameTimestampMonotonic=10;
    c.sourceKind=LGLocalSourceLiveAppOwnedTexture; c.alphaMode=LGLocalAlphaOpaque;
    c.maskKind=LGLocalMaskRounded44; c.backgroundOnly=true;
    c.targetForegroundExcluded=true; c.immutableUntilFrameReleased=true;
    c.sampledRGBIsLinear=true; c.sampledRGBIsPremultiplied=true;
    c.sourceOverscanEnabled=true;
    LGLocalButtonSourceLayout layout={0};
    assert(LGLocalSourceLayoutForContract(&c,152,152,&layout));
    assert(layout.targetPixelWidth==88 && layout.targetPixelHeight==88);
    assert(layout.leftPaddingPoints==16 && layout.topPaddingPoints==16);
    assert(LGLocalValidateSourceContract(&c,10.05,11,2,3,9,152,152,81,81,true,false)
           ==LGLocalSourceValid);
    c.sourceRectInOwnerPoints.origin.x=3.999;
    assert(LGLocalValidateSourceContract(&c,10.05,11,2,3,9,152,152,81,81,true,false)
           ==LGLocalSourceBadGeometry);
    c.sourceRectInOwnerPoints=CGRectMake(4,8,76,76); c.sourceOverscanEnabled=false;
    assert(!LGLocalSourceLayoutForContract(&c,152,152,&layout));
    c.sourceOverscanEnabled=true; c.alphaMode=LGLocalAlphaStraight;
    assert(LGLocalValidateSourceContract(&c,10.05,11,2,3,9,152,152,81,81,true,false)
           ==LGLocalSourceBadAlpha);
    c.alphaMode=LGLocalAlphaOpaque; c.sampledRGBIsPremultiplied=false;
    assert(LGLocalValidateSourceContract(&c,10.05,11,2,3,9,152,152,81,81,true,false)
           ==LGLocalSourceBadAlpha);
}

int main(void) {
    test_slot_lease_epochs();
    test_bounded_three_slot_ring();
    test_value_contract_uses_exact_opaque_domain();
    puts("App-owned bounded lease/value tests passed");
    return 0;
}
