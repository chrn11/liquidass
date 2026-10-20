/* Pure-C regression fixture for the existing optical state machine.
 * It intentionally does not compile or model any local material/provider code.
 * macOS CI may compile it using the repository's existing C test harness.
 */
#include <assert.h>
#include <math.h>
#include "../Shared/LGButtonOpticalState.h"

int main(void) {
    LGButtonOpticalState state;
    LGOpticalReset(&state, 41);

    /* This is the adapter rule: local eligibility is ORed with the legacy CA
     * gate, so the established reducer/state can run while CA pressure is off. */
    const bool localExplicitOptIn = true;
    const bool legacyPressureGate = false;
    const bool adapterCandidate = localExplicitOptIn || legacyPressureGate;
    assert(LGOpticalSetEligibility(&state, adapterCandidate, true, true,
                                   true, true, 41));
    assert(state.eligible && state.geometryGeneration == 41);

    assert(LGOpticalBegin(&state, 10.0, true, true,
                          22.0f, 22.0f, 44.0f, 44.0f));
    assert(state.tracking && state.target == 1.0f && state.touchValid);
    assert(fabsf(state.touchX - 0.5f) < 0.0001f);
    assert(fabsf(state.touchY - 0.5f) < 0.0001f);
    assert(LGOpticalTick(&state, 10.065));
    assert(state.pressure > 0.0f && state.pressure <= 1.0f);

    LGOpticalEnd(&state, 10.08, false);
    assert(!state.tracking && state.target == 0.0f && state.wantsFrames);
    assert(LGOpticalPressureIndex(&state, 9u) > 0u);

    /* Explicit local off and no legacy CA opt-in reset the same state and stop
     * its frame driver; no second reducer or synthetic input is involved. */
    assert(!LGOpticalSetEligibility(&state, false, true, true, true, true, 41));
    assert(!state.eligible && !state.tracking && !state.wantsFrames);
    assert(LGOpticalPressureIndex(&state, 9u) == 0u);
    return 0;
}
