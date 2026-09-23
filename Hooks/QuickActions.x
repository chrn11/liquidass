#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import <objc/runtime.h>

static void *kQAGlassKey = &kQAGlassKey;
static void *kQABackdropKey = &kQABackdropKey;
static void *kQABackdropAlphaKey = &kQABackdropAlphaKey;
static void *kQAOriginalStyleKey = &kQAOriginalStyleKey;
static void *kQAOriginalContentStyleKey = &kQAOriginalContentStyleKey;
static void *kQAOriginalStyleCapturedKey = &kQAOriginalStyleCapturedKey;
static NSHashTable<UIVisualEffectView *> *sQuickActionHosts;
static void removeQuickActionsGlass(UIVisualEffectView *fx);

static UIView *qaBackdropView(UIView *effectView) {
    for (UIView *sub in effectView.subviews) {
        if ([sub isKindOfClass:[LGLiveBackdropView class]]) continue;
        if ([NSStringFromClass(sub.class) containsString:@"Backdrop"]) return sub;
        for (UIView *inner in sub.subviews) {
            if ([inner isKindOfClass:[LGLiveBackdropView class]]) continue;
            if ([NSStringFromClass(inner.class) containsString:@"Backdrop"]) return inner;
        }
    }
    return nil;
}

static BOOL qaSetBackdropHidden(UIVisualEffectView *effectView) {
    UIView *backdrop = qaBackdropView(effectView);
    if (!backdrop) return NO;

    UIView *savedBackdrop = objc_getAssociatedObject(effectView, kQABackdropKey);
    NSNumber *savedAlpha = objc_getAssociatedObject(effectView, kQABackdropAlphaKey);
    if (savedBackdrop && savedBackdrop != backdrop && savedAlpha)
        savedBackdrop.alpha = savedAlpha.doubleValue;

    if (savedBackdrop != backdrop || !savedAlpha) {
        objc_setAssociatedObject(effectView, kQABackdropKey, backdrop,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(effectView, kQABackdropAlphaKey, @(backdrop.alpha),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    backdrop.alpha = 0.0;
    return YES;
}

static BOOL qaStockBackdropSaved(UIVisualEffectView *effectView) {
    return objc_getAssociatedObject(effectView, kQABackdropAlphaKey) != nil;
}

static void qaRestoreStockBackdrop(UIVisualEffectView *effectView) {
    UIView *backdrop = objc_getAssociatedObject(effectView, kQABackdropKey);
    NSNumber *alpha = objc_getAssociatedObject(effectView, kQABackdropAlphaKey);
    if (backdrop && alpha) backdrop.alpha = alpha.doubleValue;
    objc_setAssociatedObject(effectView, kQABackdropKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(effectView, kQABackdropAlphaKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void qaCaptureOriginalStyle(UIVisualEffectView *effectView) {
    if (objc_getAssociatedObject(effectView, kQAOriginalStyleCapturedKey)) return;
    objc_setAssociatedObject(effectView, kQAOriginalStyleKey,
        @((NSInteger)effectView.overrideUserInterfaceStyle), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(effectView, kQAOriginalContentStyleKey,
        @((NSInteger)effectView.contentView.overrideUserInterfaceStyle), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(effectView, kQAOriginalStyleCapturedKey, @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void qaRestoreOriginalStyle(UIVisualEffectView *effectView) {
    if (!objc_getAssociatedObject(effectView, kQAOriginalStyleCapturedKey)) return;
    NSNumber *style = objc_getAssociatedObject(effectView, kQAOriginalStyleKey);
    NSNumber *contentStyle = objc_getAssociatedObject(effectView, kQAOriginalContentStyleKey);
    if (@available(iOS 13.0, *)) {
        effectView.overrideUserInterfaceStyle = style
            ? (UIUserInterfaceStyle)style.integerValue : UIUserInterfaceStyleUnspecified;
        effectView.contentView.overrideUserInterfaceStyle = contentStyle
            ? (UIUserInterfaceStyle)contentStyle.integerValue : UIUserInterfaceStyleUnspecified;
    }
    objc_setAssociatedObject(effectView, kQAOriginalStyleKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(effectView, kQAOriginalContentStyleKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(effectView, kQAOriginalStyleCapturedKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static BOOL isQuickActionsHost(UIView *view) {
    if (![view isKindOfClass:[UIVisualEffectView class]] || !view.window) return NO;
    if (view.window.safeAreaInsets.bottom <= 0.0) return NO;
    Class qaCls = NSClassFromString(@"CSQuickActionsButton");
    for (UIView *a = view.superview; a; a = a.superview) {
        if (qaCls && [a isKindOfClass:qaCls]) return YES;
        if ([a isKindOfClass:[UIVisualEffectView class]]) return NO;
    }
    return NO;
}

static void injectQuickActionsGlass(UIVisualEffectView *fx) {
    if (!lgHostEnabled(@"QuickActions")) {
        removeQuickActionsGlass(fx);
        return;
    }
    UIView *container = fx.contentView;
    if (CGRectGetWidth(container.bounds) < 4.0 || CGRectGetHeight(container.bounds) < 4.0) return;

    LGLiveBackdropView *glass = objc_getAssociatedObject(fx, kQAGlassKey);
    BOOL hadStock = qaStockBackdropSaved(fx);
    if (!glass) {
        glass = LGCreateRegisteredGlass(container.bounds, nil, @"QuickActions");
        if (!glass) {
            if (hadStock) {
                qaRestoreOriginalStyle(fx);
                qaRestoreStockBackdrop(fx);
            }
            return;
        }
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [container insertSubview:glass atIndex:0];
        objc_setAssociatedObject(fx, kQAGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != container) [container insertSubview:glass atIndex:0];
    glass.frame               = container.bounds;
    glass.layer.cornerRadius  = fmin(CGRectGetWidth(container.bounds), CGRectGetHeight(container.bounds)) * 0.5;
    glass.layer.cornerCurve   = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;
    [glass applyFilters];

    // Don't suppress Apple's backdrop until our CA filter is attached.
    if (!glass.lgFilterAttached) {
        if (hadStock) {
            qaRestoreOriginalStyle(fx);
            qaRestoreStockBackdrop(fx);
        }
        [glass removeFromSuperview];
        objc_setAssociatedObject(fx, kQAGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }

    qaCaptureOriginalStyle(fx);
    if (@available(iOS 13.0, *)) {
        fx.overrideUserInterfaceStyle        = UIUserInterfaceStyleLight;
        container.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
    if (!qaSetBackdropHidden(fx)) {
        removeQuickActionsGlass(fx);
        return;
    }
    if (!sQuickActionHosts) sQuickActionHosts = [NSHashTable weakObjectsHashTable];
    [sQuickActionHosts addObject:fx];
    lgTrackGlass(glass, @"QuickActions", nil);
}

static void removeQuickActionsGlass(UIVisualEffectView *fx) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(fx, kQAGlassKey);
    qaRestoreOriginalStyle(fx);
    qaRestoreStockBackdrop(fx);
    if (glass) {
        [glass removeFromSuperview];
        objc_setAssociatedObject(fx, kQAGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    [sQuickActionHosts removeObject:fx];
}


static void LGReconcileQuickActionHosts(void) {
    for (UIVisualEffectView *host in sQuickActionHosts.allObjects) {
        if (lgHostEnabled(@"QuickActions")) injectQuickActionsGlass(host);
        else removeQuickActionsGlass(host);
    }
}

%hook UIVisualEffectView
- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!self_.window) { removeQuickActionsGlass((UIVisualEffectView *)self_); return; }
    if (isQuickActionsHost(self_)) injectQuickActionsGlass((UIVisualEffectView *)self_);
}
- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (isQuickActionsHost(self_)) injectQuickActionsGlass((UIVisualEffectView *)self_);
}
%end

%ctor {
    lgObservePreferenceReload(^{ LGReconcileQuickActionHosts(); });
}
