#pragma once
#include <stdbool.h>
/* Release blocker, not a fabricated producer-proof API.
 * Current ourCustomRender13 has no producer frame lease, write-complete
 * event/value or trusted frame-bound color/scene contract. Preferences, pixel
 * format81, IOSurface metadata alone and the snapshot alpha audit cannot supply
 * those missing facts. Therefore NO existing callback is admitted, even when
 * the optional profile is compiled and explicitly requested.
 *
 * There is intentionally no bool argument, environment override, registry
 * setter, token constructor or test macro that can promote this function.
 * Replacing this denial requires an actual producer integration and review;
 * low-level synthetic Metal tests remain tests, not production authorization.
 * No system208B uniform or existing legacy shader changes are involved. */
static inline bool LGCAClosedProductionSourceAdmitted(void) {
    return false;
}
