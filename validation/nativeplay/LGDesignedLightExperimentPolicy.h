#pragma once
#include <stdbool.h>
#include <math.h>
/* Test-carrier safety policy only; no change to optical ABI or source validity. */
static inline bool LGDLExperimentMayEnable(bool rendererCompiled, bool effectiveOptIn,
    bool requested, bool ownBundle, bool pipelineReady, bool captureReady) {
    return rendererCompiled && effectiveOptIn && requested && ownBundle && pipelineReady && captureReady;
}
static inline bool LGDLPrimaryStrengthIsOn(float strength) {
    return isfinite(strength) && strength==1.0f;
}
