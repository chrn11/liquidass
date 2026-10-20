#pragma once
#import <UIKit/UIKit.h>
#import "LGLocalButtonMaterialView.h"

NS_ASSUME_NONNULL_BEGIN

#define LG_SETTINGS_BACK_BUTTON_LOCAL_RENDERER_PREF @"PrefsButton.LocalRenderer.Enabled"

/* Public host entry point. Pass the existing exact LGSettingsBackButton control
 * and an app-owned, same-process provider. Pass nil provider to unbind. Binding
 * and unbinding are main-thread-only; no provider is discovered or guessed.
 * The implementation rejects every other control/class/process/target geometry.
 */
#ifdef __cplusplus
extern "C" {
#endif
FOUNDATION_EXPORT BOOL LGSettingsBackButtonBindLocalButtonSourceProvider(
    UIControl * _Nullable target,
    id<LGLocalButtonSourceProvider> _Nullable sourceProvider,
    BOOL allowApproximateSource);
#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
