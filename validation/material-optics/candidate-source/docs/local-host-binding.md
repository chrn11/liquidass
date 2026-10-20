# LGSettingsBackButton → local renderer binding (source-only)

This change is a narrow adapter for the **existing exact `LGSettingsBackButton`** in `com.apple.Preferences`. It adds no renderer/material/provider implementation and changes no shader, numerical coefficients, uniform ABI, source contract, CA routing, Backboard, other control host, or target/action/haptic/AX/glyph behavior. `LGLocalButtonMaterialView` and `LGLocalButtonSourceProvider` remain the single existing renderer and provider contract. The only build-manifest adjustment explicitly adds the already-existing `.mm` implementation (the baseline `Shared/*.[xm]` pattern does not include `.mm`) and links its existing `Metal`/`MetalKit` dependencies; CI configuration is untouched.

## Closed by default

`LG_LOCAL_BUTTON_RENDERER_COMPILED` remains defined as `0` by default in `LGLocalButtonSourceContract.h`. Even when a future macOS/Xcode build explicitly sets it to `1`, there is no automatic provider discovery or local-view construction. Binding additionally requires the preferences plist key `PrefsButton.LocalRenderer.Enabled` to be an actual `NSNumber` whose value is true. Missing, string, or false values deny opt-in. The existing `PrefsButton.MaterialCandidate.Enabled`/settings-host eligibility must also already have made the button's candidate material active.

With default macro/prefs or no host binding, no local view/device/provider callback/timer/notification is created; `lg_opticalRefreshEligibility` and `lg_opticalSubmit` retain the legacy CA path. Per-control resign/active observers exist only after a successful explicit bind and are removed on unbind/detach. A local source is never inferred from a window/superview color, stock UIKit view, screenshot, or synthetic background. The provider must satisfy the pre-existing same-process immutable-frame/lease/100-ms/identity/geometry/source contract and should not strongly retain the bound control.

## Public host entry point

Include `Shared/LGSettingsBackButtonLocalBinding.h` in the separate host integration. It exports a C-linkage-guarded symbol:

```objc
BOOL LGSettingsBackButtonBindLocalButtonSourceProvider(
    UIControl *target,
    id<LGLocalButtonSourceProvider> sourceProvider,
    BOOL allowApproximateSource);
```

Call it on the main thread only, with a reference to the already-existing returned control and the app-owned provider. Example (the host's integration owns both references; this is not a new hook or a hierarchy/background search):

```objc
#import "LGSettingsBackButtonLocalBinding.h"

// returnControl is the already-created exact LGSettingsBackButton instance.
// provider implements the existing LGLocalButtonSourceProvider contract.
BOOL bound = LGSettingsBackButtonBindLocalButtonSourceProvider(
    returnControl, provider, NO); // deny approximate source by default

// On host opt-out, provider teardown, or replacement, explicitly unbind first:
BOOL unbound = LGSettingsBackButtonBindLocalButtonSourceProvider(
    returnControl, nil, NO);
```

The implementation rejects non-exact runtime class, non-`com.apple.Preferences` bundle, wrong `_UINavigationBarContentView`/stock back-button target, inactive candidate, absent local NSNumber opt-in, missing window, disabled/hidden control, non-44pt bounds/converted target rect, non-identity transform, and non-idle/tracking registration. The function intentionally refuses binding during tracking/press-scale animation; call again only once the existing control is idle and geometrically 44×44. Rebinding always invalidates and detaches the previous per-control local view and restores its own legacy glass before attempting the new provider. A failed new bind leaves the original path visible.

The callback on `LGLocalButtonMaterialView.availabilityChangedHandler` is main-thread-only and per renderer instance. `YES` means an actual completed frame is still source/owner/target-geometry valid and within its original 100ms source deadline. During a valid refresh it may remain true on the separately retained previous completion; it never asserts that the new pending serial has completed. `hasCurrentCompletedValidSubmission` remains strict about the current serial, while `hasDisplayableCompletedMaterial` allows only a still-fresh prior actual completion. Clear, expiry, opt-out, detach, rejected source or GPU execution failure revokes availability. A fresh pending source cannot extend an old completion's lifetime. This is not screen-presentation proof. The owner is weakly captured by the callback.

## Geometry, feedback and fallback

The renderer is inserted as a noninteractive sibling under the same parent as the exact 44×44 target. Both the converted target rect and source contract must remain 44×44. The source target is not enlarged to match the existing `setHighlighted:` 1.16 transform: local binding is idle-only, and after a real completed valid **idle** local submission the local visual-feedback branch suppresses only that button's old visual transform and keeps identity geometry while the existing `LGButtonOpticalState` is submitted directly to `submitOpticalState:`. The legacy spring constants/scale remain unchanged and run verbatim whenever local feedback is not armed/valid. This is visual-only; original `begin/continue/end/cancelTracking`, point subtraction, event dispatch, return action, haptic, 44pt bounds, glyph and accessibility remain in place.

The only hidden-state override is the button's own old `glass` view, and only after the local renderer reports true. It records the prior value and weak object identity; on false/replacement it restores only that same current glass object when it is still hidden by this override. It never hides/modifies the target, stock UIKit controls, glyph, or other layers. Unavailable/expired/rejected sources leave or restore the old glass/current/native path; a failed in-flight local press restores the original visual scale on the exact control. After geometry is identity and idle again, the same explicitly bound provider may be queried on a subsequent existing optical submit. The host should call the public nil-provider unbind as part of its own immediate opt-out path; the hook also removes a bound view when its NSNumber preference is observed false on a later eligibility refresh.

## Validation prepared (not compiled here)

- `scripts/test_settings_back_button_local_binding.py` is a Python source/mechanical guard for the single state route, exact target/API/default-off gates, serial-completion callback, same-glass restoration and changed-file scope.
- `scripts/test_settings_back_button_local_state.c` is a pure-C regression fixture for the existing `LGButtonOpticalState` reducer, demonstrating local eligibility independent of the legacy CA pressure gate and explicit-off reset. It is deliberately **not** compiled here.
- No clang/ObjC/C++/link/Metal compile, device/runtime test, CI run, provider implementation, screen inspection or installation is claimed. The external AppOwnedProvider file and later authorized macOS/Xcode validation are still separate work.

## Bounded idle source renewal (build25)

After an explicit eligible visible/active binding, the original host now actually calls `lg_localUpdateIdleRefreshForResult:` from `lg_opticalSubmit`. While idle, a weak one-shot timer renews at no more than15Hz; tracking/wantsFrames continues to use the original shared state driver, not a second reducer. Opt-out, detach, hidden/inactive and unbind stop the idle timer. At most three consecutive unavailable/rejected or Ready-without-real-completion intervals are attempted; Ready alone does not reset this budget. Actual completion or a later explicit host event may resume. No default/off-path device or timer is added.

The material view separately retains at most one last completed immutable frame, in addition to its pending frame and bounded GPU uses. Both original source timestamps are checked; the single expiry timer is scheduled for the earlier deadline. A leased previous texture cannot be overwritten by the provider. If no actual completed content remains, the local layer is suppressed and the old fallback restored, even when a newer source is fresh but still pending. Internal first-frame suppression does not masquerade as a host alpha opt-out; external host alpha below0.01 still clears the material. Each explicit submit coalesces at most one pending main-queue `draw` request, not a render loop.

GitHub Actions macOS run38936468240 compiled the actual Hook, provider and renderer in both iOS architectures/gate settings and ran value/Metal regressions. The original authorized App's build25 actual class tests passed pending-at50ms retention, old100ms-deadline invalidation while new source remains valid, new actual completion, synchronous callback cancellation, asymmetric source orientation and exact2pt ROI movement. The original Settings hook's timer, fallback visibility and actions are **not yet enabled/run in Settings**; fixture-level success is not a real system-host or screen-visual acceptance. All sources stay default-off.
