#pragma once
/* Pure value policy shared by the bounded App-owned texture ring and C tests.
 * Callers provide their own lock; this header has no UIKit/Metal dependencies. */
#include <stdbool.h>
#include <stdint.h>

#define LG_APP_OWNED_TEXTURE_SLOT_COUNT 3u
#define LG_APP_OWNED_MAX_LEASES_PER_SLOT 4u

typedef struct {
    uint64_t epoch;
    uint64_t ownerGeneration;
    uint32_t leaseCount;
    bool published;
    bool writing;
} LGAppOwnedLeaseSlotValue;

static inline bool LGAppOwnedLeaseReserve(LGAppOwnedLeaseSlotValue *slot,
                                           uint64_t ownerGeneration,
                                           uint64_t *outEpoch) {
    if (!slot || !outEpoch || !ownerGeneration || slot->writing ||
        slot->leaseCount != 0u || slot->epoch == UINT64_MAX) return false;
    slot->epoch++;
    slot->ownerGeneration=ownerGeneration;
    slot->published=false;
    slot->writing=true;
    *outEpoch=slot->epoch;
    return true;
}

static inline bool LGAppOwnedLeasePublish(LGAppOwnedLeaseSlotValue *slot,
                                           uint64_t ownerGeneration,
                                           uint64_t epoch) {
    if (!slot || !ownerGeneration || !epoch || !slot->writing ||
        slot->published || slot->ownerGeneration!=ownerGeneration ||
        slot->epoch!=epoch || slot->leaseCount!=0u) return false;
    slot->writing=false;
    slot->published=true;
    slot->leaseCount=1u;
    return true;
}

static inline bool LGAppOwnedLeaseAbortWrite(LGAppOwnedLeaseSlotValue *slot,
                                              uint64_t ownerGeneration,
                                              uint64_t epoch) {
    if (!slot || !slot->writing || slot->ownerGeneration!=ownerGeneration ||
        slot->epoch!=epoch || slot->leaseCount!=0u) return false;
    slot->writing=false;
    slot->published=false;
    slot->ownerGeneration=0;
    return true;
}

/* Acquire one frame object for a published immutable capture. A zero-lease
 * published slot may still be returned from the <=66ms capture cache. */
static inline bool LGAppOwnedLeaseAcquire(LGAppOwnedLeaseSlotValue *slot,
                                           uint64_t ownerGeneration,
                                           uint64_t epoch) {
    if (!slot || !ownerGeneration || !epoch || slot->writing ||
        !slot->published || slot->ownerGeneration!=ownerGeneration ||
        slot->epoch!=epoch ||
        slot->leaseCount>=LG_APP_OWNED_MAX_LEASES_PER_SLOT) return false;
    slot->leaseCount++;
    return true;
}

/* Stale completion/dealloc callbacks are harmless: they cannot decrement a
 * later slot epoch or a capture from another owner generation. */
static inline bool LGAppOwnedLeaseEnd(LGAppOwnedLeaseSlotValue *slot,
                                       uint64_t ownerGeneration,
                                       uint64_t epoch) {
    if (!slot || !ownerGeneration || !epoch || slot->writing ||
        !slot->published || slot->ownerGeneration!=ownerGeneration ||
        slot->epoch!=epoch || slot->leaseCount==0u) return false;
    slot->leaseCount--;
    return true;
}

static inline bool LGAppOwnedLeaseCanReserve(const LGAppOwnedLeaseSlotValue *slot) {
    return slot && !slot->writing && slot->leaseCount==0u &&
           slot->epoch!=UINT64_MAX;
}
