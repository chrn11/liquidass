#pragma once
#include <stdint.h>
#include <stdbool.h>
#include "LGButtonMaterialCandidate.h"
#ifndef LG_CA_CLOSED_PROFILE_COMPILED
#define LG_CA_CLOSED_PROFILE_COMPILED 0
#endif
/* A new opt-in CA profile, NOT the app-owned 240B renderer contract. */
static inline bool LGCAClosedProfileMayUse(bool compiledExactlyOne, bool explicitlyRequested,
    bool exactCandidateAtom, bool oldCandidateGatesPassed, uint32_t sourceFormat,
    uint32_t destinationFormat, bool sameDevice, bool distinctTextures,
    float sourceWidth, float sourceHeight, float destinationWidth, float destinationHeight,
    float rendererScale) {
    LGButtonOpticsGeometry geometry={0};
    return compiledExactlyOne && explicitlyRequested && exactCandidateAtom && oldCandidateGatesPassed &&
        sourceFormat==81u && destinationFormat==81u && sameDevice && distinctTextures &&
        LGButtonCandidateBuildGeometry(sourceWidth,sourceHeight,destinationWidth,destinationHeight,
            rendererScale,&geometry);
}
