#pragma once
/* Pure value policy for the explicitly bound Settings host. No UIKit, timer,
 * provider, renderer, or source-contract ownership is hidden in this header. */
#include <stdbool.h>
#include <stdint.h>
#include <math.h>
#include "LGLocalButtonSourceContract.h"

#define LG_LOCAL_IDLE_REFRESH_MAX_HZ 15u
#define LG_LOCAL_IDLE_REFRESH_RETRY_LIMIT 3u
#define LG_LOCAL_IDLE_REFRESH_INTERVAL_SECONDS (1.0 / 15.0)

typedef enum {
    LGLocalIdleRefreshAttemptUsable=0,
    LGLocalIdleRefreshAttemptUnavailable,
    LGLocalIdleRefreshAttemptRejected
} LGLocalIdleRefreshAttempt;

/* The host schedules an idle refresh only while its explicit binding and the
 * exact source/button remain opted-in, eligible, visible, and foreground. */
static inline bool LGLocalIdleRefreshShouldRun(bool explicitlyBound,
    bool preferenceEnabled, bool hostEligible, bool visible, bool active,
    bool tracking, bool wantsFrames) {
    return explicitlyBound && preferenceEnabled && hostEligible && visible &&
        active && !tracking && !wantsFrames;
}

static inline double LGLocalIdleRefreshInterval(void) {
    return LG_LOCAL_IDLE_REFRESH_INTERVAL_SECONDS;
}

/* Exactly three consecutive unavailable/rejected idle attempts are allowed;
 * a later external host event may start a new bounded sequence. */
static inline uint32_t LGLocalIdleRefreshFailureCount(uint32_t previous,
                                                       bool failed) {
    if (!failed) return 0u;
    return previous < LG_LOCAL_IDLE_REFRESH_RETRY_LIMIT ? previous + 1u : previous;
}
static inline bool LGLocalIdleRefreshMayRetry(uint32_t failures) {
    return failures < LG_LOCAL_IDLE_REFRESH_RETRY_LIMIT;
}

/* Availability may be backed by an actually completed current submission or
 * by the separately retained last completed frame while that lease is fresh. */
static inline bool LGLocalStableCompletedAvailability(bool currentCompleted,
                                                        bool retainedCompletedValid) {
    return currentCompleted || retainedCompletedValid;
}

/* Value boundary shared with retained-frame expiry tests. Contract validation
 * still checks owner token/generation, geometry, texture and all source fields. */
static inline bool LGLocalRetainedCompletionFresh(double now,
    double sourceTimestamp, bool sameOwner, bool sameGeometry,
    bool ownerAlive, bool hostEligible) {
    if (!sameOwner || !sameGeometry || !ownerAlive || !hostEligible ||
        !isfinite(now) || !isfinite(sourceTimestamp)) return false;
    double age=now-sourceTimestamp;
    return age >= -LG_LOCAL_BUTTON_FUTURE_SLOP_SECONDS &&
           age <= LG_LOCAL_BUTTON_SOURCE_MAX_AGE_SECONDS;
}
