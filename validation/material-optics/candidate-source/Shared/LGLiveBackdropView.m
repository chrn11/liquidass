#import "LGLiveBackdropView.h"
#import "LGGlassKit.h"
#import "LGHostRegistry.h"
#import "LGButtonPressureRoute.h"
#import "LGCoverSheetState.h"
#import <CoreMotion/CoreMotion.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <time.h>
#import <math.h>
#import <unistd.h>
#import <stdatomic.h>

static const void *kLGOutsetKey = &kLGOutsetKey;
static const void *kLGRadiusKey = &kLGRadiusKey;
static const void *kLGSpecularEnabledOverrideKey = &kLGSpecularEnabledOverrideKey;

static NSDictionary<NSString *, id> *sLGGlassPreferences;

static NSString *LGGlassPreferencesPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        path = jbroot(@"/var/mobile/Library/Preferences/dylv.liquidassprefs.plist");
    });
    return path;
}

id LGGlassPreferenceValue(NSString *key) {
    if (!key.length) return nil;
    @synchronized([LGLiveBackdropView class]) {
        if (!sLGGlassPreferences) {
            sLGGlassPreferences =
                [NSDictionary dictionaryWithContentsOfFile:LGGlassPreferencesPath()] ?: @{};
        }
        return sLGGlassPreferences[key];
    }
}

LGSurfaceBackgroundProfile LGSurfaceBackgroundProfileForHost(NSString *prefix) {
    id value = prefix.length ? LGGlassPreferenceValue(
        [prefix stringByAppendingString:@".BackgroundProfile"]) : nil;
    value = value ?: (prefix.length ? LGGlassPreferenceValue(
        [NSString stringWithFormat:@"%@.%@", LG_SURFACE_BACKGROUND_PROFILE_KEY, prefix]) : nil);
    return LGSurfaceBackgroundProfileFromPreference(value ?:
        LGGlassPreferenceValue(LG_SURFACE_BACKGROUND_PROFILE_KEY));
}

LGSurfaceQualityTier LGSurfaceQualityTierForHost(NSString *prefix) {
    id value = prefix.length ? LGGlassPreferenceValue(
        [prefix stringByAppendingString:@".QualityTier"]) : nil;
    value = value ?: (prefix.length ? LGGlassPreferenceValue(
        [NSString stringWithFormat:@"%@.%@", LG_SURFACE_QUALITY_TIER_KEY, prefix]) : nil);
    value = value ?: LGGlassPreferenceValue(LG_SURFACE_QUALITY_TIER_KEY);
    return value ? LGSurfaceQualityTierFromPreference(value)
                 : LGSurfaceQualityTierFromGlobalQualityPreference(LGGlassPreferenceValue(@"Global.Quality"));
}

void LGInvalidateGlassPreferenceCache(void) {
    @synchronized([LGLiveBackdropView class]) {
        sLGGlassPreferences = nil;
    }
}

NSString *LGFilterTypeForHostPrefix(NSString *prefix) {
    if (!prefix.length) return nil;
    const LGHostDefinition *host =
        LGHostDefinitionForPreferencePrefix(prefix.UTF8String);
    return host ? [NSString stringWithUTF8String:host->filterType] : nil;
}

static void sblog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void sblog(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *format = [NSString stringWithUTF8String:fmt ?: ""];
    NSString *message = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    LGLog(@"[LGSB] %@", message);
}

static const NSInteger kLGDynamicRadiusSteps = 32;

static BOOL LGNeedsGaussianIdentityFallback(void) {
    return access("/var/mobile/Library/Accessibility/liquidass-gaussian-identity-state.bin",
                  F_OK) == 0;
}

static CFStringRef const kLGParametersReloadedNotification =
    CFSTR("dylv.liquidglass/ParametersReloaded");
static NSHashTable<LGLiveBackdropView *> *sLGAllGlasses;
static BOOL sLGFilterRefreshSetup;
static NSHashTable<UIView *> *sLGInternalStockMutations;

static void LGEnsureInternalStockMutations(void) {
    @synchronized([LGLiveBackdropView class]) {
        if (!sLGInternalStockMutations)
            sLGInternalStockMutations = [NSHashTable weakObjectsHashTable];
    }
}

static BOOL LGInternalStockMutationContains(UIView *material) {
    @synchronized([LGLiveBackdropView class]) {
        return [sLGInternalStockMutations containsObject:material];
    }
}

static void LGInternalStockMutationAdd(UIView *material) {
    @synchronized([LGLiveBackdropView class]) {
        [sLGInternalStockMutations addObject:material];
    }
}

static void LGInternalStockMutationRemove(UIView *material) {
    @synchronized([LGLiveBackdropView class]) {
        [sLGInternalStockMutations removeObject:material];
    }
}

BOOL LGIsInternalStockMaterialVisibilityMutation(UIView *material) {
    if (!material) return NO;
    LGEnsureInternalStockMutations();
    return LGInternalStockMutationContains(material);
}

static void LGSetStockMaterialHiddenInternally(UIView *material, BOOL hidden) {
    if (!material) return;
    LGEnsureInternalStockMutations();
    LGInternalStockMutationAdd(material);
    @try {
        material.hidden = hidden;
    } @finally {
        LGInternalStockMutationRemove(material);
    }
}

static BOOL LGSpecularEnabledForFilterType(NSString *type) {
    const LGHostDefinition *host = LGHostDefinitionForFilterType(type.UTF8String);
    if (host == &kLGHostRegistry[LGHostIdentifierCoverSheet]) return NO;
    if (host && host->specularOpacity <= 0.001f) return NO;
    NSString *prefix = host ? [NSString stringWithUTF8String:host->preferencePrefix] : nil;
    if (!prefix.length) return YES;
    id value = LGGlassPreferenceValue([prefix stringByAppendingString:@".SpecularEnabled"]);
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : YES;
}

static NSHashTable<LGLiveBackdropView *> *sLGMotionGlasses;
static CMMotionManager *sLGMotionManager;
static NSOperationQueue *sLGMotionQueue;
static BOOL sLGMotionSetup;
static BOOL sLGMotionRunning;
static CGFloat sLGSpecularAngle = -M_PI_4;
static CGFloat sLGTargetSpecularAngle = -M_PI_4;
static CGFloat sLGLastTargetSpecularAngle = -M_PI_4;
static CGFloat sLGLastAppliedSpecularAngle = -100.0;
static CADisplayLink *sLGMotionDisplayLink;
static BOOL sLGMotionEnabled;
static CGFloat sLGMotionSensitivity = 2.0;
static CGFloat sLGMotionLoggedSensitivity = -1.0;
static CFStringRef const kLGMotionPrefsReloadNotification = CFSTR("dylv.liquidassprefs/Reload");

static void LGApplyMotionHighlightAngle(void);
static void LGRefreshMotionHighlights(void);
static void LGEnsureFilterRefreshObserver(void);

@interface LGMotionDisplayLinkTarget : NSObject
- (void)tick:(CADisplayLink *)displayLink;
@end

static BOOL LGIsSpringBoardBundle(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
}

static void LGReloadMotionHighlightPreferences(void) {
    id enabled = LGGlassPreferenceValue(@"Specular.Motion.Enabled");
    id sensitivity = LGGlassPreferenceValue(@"Specular.Motion.Sensitivity");
    BOOL previousEnabled = sLGMotionEnabled;
    CGFloat previousSensitivity = sLGMotionSensitivity;
    sLGMotionEnabled = [enabled respondsToSelector:@selector(boolValue)] ? [enabled boolValue] : NO;
    CGFloat value = [sensitivity respondsToSelector:@selector(doubleValue)] ? [sensitivity doubleValue] : 2.0;
    sLGMotionSensitivity = MAX(0.0, MIN(8.0, value));
    if (sLGMotionLoggedSensitivity < 0.0 || previousEnabled != sLGMotionEnabled ||
        fabs(previousSensitivity - sLGMotionSensitivity) > 0.01) {
        sLGMotionLoggedSensitivity = sLGMotionSensitivity;
        LGLog(@"motion highlights prefs enabled=%d sensitivity=%.2f", sLGMotionEnabled, sLGMotionSensitivity);
    }
}

static void LGMotionPreferencesDidChange(CFNotificationCenterRef center, void *observer,
                                         CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        LGInvalidateGlassPreferenceCache();
        LGReloadMotionHighlightPreferences();
        LGRefreshMotionHighlights();
    });
}

static BOOL LGUsesDynamicRadiusType(NSString *filterType) {

    return filterType.length &&
           LGHostIdentifierForFilterType(filterType.UTF8String) != LGHostIdentifierClock;
}

static BOOL LGUsesPrefsControlCaptureScale(NSString *filterType) {
    switch (LGHostIdentifierForFilterType(filterType.UTF8String)) {
        case LGHostIdentifierPrefsSlider:
        case LGHostIdentifierPrefsSwitch:
        case LGHostIdentifierPrefsButton:
        case LGHostIdentifierPrefsButtonCandidate:
        case LGHostIdentifierPrefsSegment:
            return YES;
        default:
            return NO;
    }
}

static CGFloat LGNativeBlurRadiusForFilterType(NSString *filterType) {
    if (LGHostIdentifierForFilterType(filterType.UTF8String) ==
        LGHostIdentifierPrefsButtonCandidate) return 0.0;
    const LGHostDefinition *host = LGHostDefinitionForFilterType(filterType.UTF8String);
    if (!host) return 0.0;
    NSString *prefix = [NSString stringWithUTF8String:host->preferencePrefix];
    id value = LGGlassPreferenceValue([prefix stringByAppendingString:@".Blur"]);
    return [value respondsToSelector:@selector(doubleValue)]
        ? MAX(0.0, [value doubleValue]) : host->blur;
}

static const CGFloat kLGScaleMax    = 0.75;
static const CGFloat kLGScaleMin    = 0.25;

static const CGFloat kLGClockCaptureScale = 0.50;

static const CGFloat kLGPrefsControlScale = 1.50;
static const CGFloat kLGDefaultScaleBudget = 8000.0;
static CGFloat LGQualityValue(void) {
    id value = LGGlassPreferenceValue(@"Global.Quality");
    CGFloat quality = [value respondsToSelector:@selector(doubleValue)]
        ? (CGFloat)[value doubleValue] : 1.0;
    if (!isfinite(quality)) quality = 1.0;
    return fmin(1.0, fmax(0.1, quality));
}

static CGFloat LGScaleBudget(void) {
    return kLGDefaultScaleBudget * LGQualityValue();
}

static CGFloat LGScaleForSize(CGSize s) {
    // area budget keeps total capture cost predictable
    CGFloat area = s.width * s.height;
    if (area <= 1.0) return kLGScaleMax;
    CGFloat scale = sqrt(LGScaleBudget() / area);
    return fmin(kLGScaleMax, fmax(kLGScaleMin, scale));
}

@interface LGLiveBackdropView ()
- (void)updateSpecular;
- (void)applySpecularAngle:(CGFloat)angle;
- (void)reapplyFilterForParameterReload;
- (void)lgSetStockMaterialRequestedHidden:(BOOL)hidden;
@end

static void LGParametersReloaded(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object,
                                 CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{

        // clear cached prefs before rebuilding every live filter
        LGInvalidateGlassPreferenceCache();
        NSArray<LGLiveBackdropView *> *glasses = sLGAllGlasses.allObjects;
        LGLog(@"render parameters ready; refreshing %lu live filters",
              (unsigned long)glasses.count);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (LGLiveBackdropView *glass in glasses) {
            [glass reapplyFilterForParameterReload];
        }
        [CATransaction commit];
    });
}

static void LGEnsureFilterRefreshObserver(void) {
    if (!sLGAllGlasses) sLGAllGlasses = [NSHashTable weakObjectsHashTable];
    if (sLGFilterRefreshSetup) return;
    sLGFilterRefreshSetup = YES;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    LGParametersReloaded,
                                    kLGParametersReloadedNotification, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

static void LGApplyMotionHighlightAngle(void) {
    if (sLGMotionGlasses.count == 0) return;
    if (sLGMotionDisplayLink && sLGMotionDisplayLink.paused &&
        fabs(sLGSpecularAngle - sLGLastAppliedSpecularAngle) < 0.001) return;
    sLGLastAppliedSpecularAngle = sLGSpecularAngle;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (LGLiveBackdropView *glass in sLGMotionGlasses.allObjects) {
        UIWindow *window = glass.window;
        if (!window || glass.hidden || glass.alpha <= 0.01 ||
            window.hidden || window.alpha <= 0.01) continue;
        CGRect bounds = glass.bounds;
        if (CGRectIsEmpty(bounds) ||
            !CGRectIntersectsRect(window.bounds, [glass convertRect:bounds toView:nil])) continue;
        [glass applySpecularAngle:sLGSpecularAngle];
    }
    [CATransaction commit];
}

@implementation LGMotionDisplayLinkTarget
- (void)tick:(CADisplayLink *)displayLink {
    CGFloat dt = displayLink.targetTimestamp > displayLink.timestamp
        ? displayLink.targetTimestamp - displayLink.timestamp : 1.0 / 60.0;
    CGFloat delta = atan2(sin(sLGTargetSpecularAngle - sLGSpecularAngle),
                          cos(sLGTargetSpecularAngle - sLGSpecularAngle));
    if (fabs(delta) < 0.001) {
        sLGSpecularAngle = sLGTargetSpecularAngle;
        LGApplyMotionHighlightAngle();
        displayLink.paused = YES;
        return;
    }
    CGFloat response = 1.0 - exp(-14.0 * dt);
    sLGSpecularAngle += delta * response;
    LGApplyMotionHighlightAngle();
}
@end

static void LGRefreshMotionHighlights(void) {
    if (!sLGMotionSetup || !LGIsSpringBoardBundle()) return;
    if (!sLGMotionEnabled) {
        [sLGMotionManager stopDeviceMotionUpdates];
        [sLGMotionDisplayLink invalidate];
        sLGMotionDisplayLink = nil;
        sLGMotionRunning = NO;
        sLGSpecularAngle = -M_PI_4;
        sLGTargetSpecularAngle = sLGSpecularAngle;
        sLGLastAppliedSpecularAngle = -100.0;
        LGApplyMotionHighlightAngle();
        return;
    }
    if (sLGMotionRunning) return;

    if (!sLGMotionQueue) {
        sLGMotionQueue = [[NSOperationQueue alloc] init];
        sLGMotionQueue.name = @"com.ngkhoi.liquidass.motion";
        sLGMotionQueue.maxConcurrentOperationCount = 1;
        sLGMotionQueue.qualityOfService = NSQualityOfServiceUtility;
    }

    CMAttitudeReferenceFrame frame = CMAttitudeReferenceFrameXArbitraryZVertical;

    sLGMotionManager.deviceMotionUpdateInterval = 1.0 / 30.0;
    static LGMotionDisplayLinkTarget *displayLinkTarget;
    if (!displayLinkTarget) displayLinkTarget = [LGMotionDisplayLinkTarget new];
    if (!sLGMotionDisplayLink) {
        sLGMotionDisplayLink = [CADisplayLink displayLinkWithTarget:displayLinkTarget
                                                           selector:@selector(tick:)];
        [sLGMotionDisplayLink addToRunLoop:NSRunLoop.mainRunLoop
                                   forMode:NSRunLoopCommonModes];
    }
    sLGMotionRunning = YES;
    [sLGMotionManager startDeviceMotionUpdatesUsingReferenceFrame:frame
                                                            toQueue:sLGMotionQueue
                                                        withHandler:^(CMDeviceMotion *motion, NSError *error) {
        if (!motion || error || !sLGMotionEnabled) return;
        CMAttitude *attitude = motion.attitude;

        CGFloat baseMotion = attitude.roll * 1.2 + attitude.pitch * 1.2 + attitude.yaw;
        CGFloat target = baseMotion * (sLGMotionSensitivity * 1.2);
        CGFloat delta = atan2(sin(target - sLGLastTargetSpecularAngle),
                              cos(target - sLGLastTargetSpecularAngle));
        if (fabs(delta) <= 0.001) return;
        sLGLastTargetSpecularAngle = target;
        sLGTargetSpecularAngle = target;
        if (sLGMotionDisplayLink && sLGMotionDisplayLink.paused) {
            dispatch_async(dispatch_get_main_queue(), ^{
                sLGMotionDisplayLink.paused = NO;
            });
        }
    }];
    LGLog(@"motion highlights started reference=tilt+yaw rate=30Hz high-sensitivity");
}

static void LGEnsureMotionHighlights(void) {
    if (!LGIsSpringBoardBundle()) return;
    if (!sLGMotionGlasses) sLGMotionGlasses = [NSHashTable weakObjectsHashTable];
    if (!sLGMotionManager) sLGMotionManager = [CMMotionManager new];
    if (!sLGMotionSetup) {
        sLGMotionSetup = YES;
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        LGMotionPreferencesDidChange,
                                        kLGMotionPrefsReloadNotification, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    LGReloadMotionHighlightPreferences();
    LGRefreshMotionHighlights();
}

static const CGFloat kLGGlassEdgeWidth = 1.0;

@implementation LGLiveBackdropView {
    LGSurfaceDescriptorV1 _lgSurfaceDescriptor;
    BOOL _lgSurfaceDescriptorInitialized;
    BOOL _lgSurfaceDescriptorHasHostBinding;
    NSString        *_lgGroupName;
    CAGradientLayer *_specularLayer;
    CAShapeLayer    *_specularMask;
    CAShapeLayer    *_edge;
    UIView          *_nativeBlurView;
    CGFloat          _nativeBlurRadius;
    BOOL             _backdropConfigured;
    BOOL             _filterAttached;
    __weak UIView   *_stockMaterialView;
    BOOL             _stockMaterialRequestedHidden;
    BOOL             _stockGlassOriginalHidden;
    CGFloat          _stockGlassOriginalAlpha;
    BOOL             _stockAlphaCaptured;
    uint32_t         _lgId;
    CGFloat          _appliedScale;
    CGFloat          _appliedBackdropZoom;
    BOOL             _parameterRefreshVariant;
    NSInteger        _lastRadiusStep;
    CGFloat          _appliedSpecularOpacity;
    NSUInteger       _buttonPressureBucket;
}

- (BOOL)lgSetButtonOpticalPressureBucket:(NSUInteger)bucket {
    if (!NSThread.isMainThread) return NO;
    BOOL validBucket = bucket < LG_BUTTON_PRESSURE_LEVELS;
    if (!validBucket) bucket = 0;
    BOOL candidate = LGHostIdentifierForFilterType(_lgFilterType.UTF8String) ==
        LGHostIdentifierPrefsButtonCandidate;
    id gate = LGGlassPreferenceValue(@LG_BUTTON_PRESSURE_PREF);
    id materialGate = LGGlassPreferenceValue(@"PrefsButton.MaterialCandidate.Enabled");
    BOOL active = LG_BUTTON_PRESSURE_EXPERIMENTAL && candidate &&
        [gate isKindOfClass:NSNumber.class] && [gate boolValue] &&
        [materialGate isKindOfClass:NSNumber.class] && [materialGate boolValue] &&
        self.window != nil && !self.hidden && self.alpha > 0.001 &&
        fabs(CGRectGetWidth(self.bounds) - 44.0) < 0.01 &&
        fabs(CGRectGetHeight(self.bounds) - 44.0) < 0.01 &&
        fabs(self.layer.cornerRadius - 22.0) < 0.01;
    NSUInteger desired = active ? bucket : 0;
    if (_buttonPressureBucket == desired) return validBucket && (active || bucket == 0);
    _buttonPressureBucket = desired;
    // No shared state, no instance pointer guessing, and no event forwarding.
    // A category change invalidates only this glass object's own CA filter.
    _filterAttached = NO;
    [self applyFilters];
    return validBucket && (active || bucket == 0);
}

- (NSString *)lgEffectiveFilterType {
    if (!_lgFilterType.length)
        return [NSString stringWithUTF8String:kLGHostRegistry[LGHostIdentifierDefault].filterType];
    NSString *base = _lgFilterType;
    if (LG_BUTTON_PRESSURE_EXPERIMENTAL && _buttonPressureBucket > 0 &&
        LGHostIdentifierForFilterType(base.UTF8String) == LGHostIdentifierPrefsButtonCandidate) {
        char name[96];
        LGButtonPressureCategory category = {(unsigned)_buttonPressureBucket,
            self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark,
            _parameterRefreshVariant};
        if (LGButtonPressureTypeName(name, sizeof name, category))
            return [NSString stringWithUTF8String:name];
    }

    if (LGUsesDynamicRadiusType(base) && !CGRectIsEmpty(self.bounds)) {
        CGFloat shortest = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds));
        BOOL keyboard = LGHostIdentifierForFilterType(base.UTF8String) ==
            LGHostIdentifierKeyboard;
        CGFloat radius = keyboard ? _lgShapeCornerRadius : self.layer.cornerRadius;
        CGFloat ratio = shortest > 0.0 ? radius / shortest : 0.0;
        CGFloat exact = MAX(0.0, MIN(0.5, ratio)) * kLGDynamicRadiusSteps;
        NSInteger step = (NSInteger)llround(exact);
        if (_lastRadiusStep >= 0 && fabs(exact - (CGFloat)_lastRadiusStep) < 0.75)
            step = _lastRadiusStep;
        _lastRadiusStep = step;
        base = [base stringByAppendingFormat:@".r%ld", (long)step];
    }
    NSString *type = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark
        ? [base stringByAppendingString:@".dark"] : base;
    if (_parameterRefreshVariant) type = [type stringByAppendingString:@".refresh"];
    return type;
}

+ (Class)layerClass {
    return NSClassFromString(@"CABackdropLayer") ?: [CALayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    return [self initWithFrame:frame groupName:nil filterType:nil];
}

- (instancetype)initWithFrame:(CGRect)frame groupName:(NSString *)groupName {
    return [self initWithFrame:frame groupName:groupName filterType:nil];
}

- (instancetype)initWithFrame:(CGRect)frame groupName:(NSString *)groupName filterType:(NSString *)filterType {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _lastRadiusStep = -1;
    _appliedSpecularOpacity = -1.0;
    _lgShapeRect = CGRectNull;
    _lgFilterType = [filterType copy];
    LGSurfaceRole role = LGSurfaceRolePanel;
    enum LGHostIdentifier host = LGHostIdentifierForFilterType(filterType.UTF8String);
    switch (host) {
        case LGHostIdentifierClock: role = LGSurfaceRoleClock; break;
        case LGHostIdentifierKeyboard: role = LGSurfaceRoleKeyboard; break;
        case LGHostIdentifierTabBarSelection: role = LGSurfaceRoleTabSelection; break;
        case LGHostIdentifierPrefsButton:
        case LGHostIdentifierPrefsButtonCandidate:
        case LGHostIdentifierQuickActions: role = LGSurfaceRoleButton; break;
        case LGHostIdentifierPrefsSlider: role = LGSurfaceRoleSlider; break;
        case LGHostIdentifierPrefsSwitch: role = LGSurfaceRoleSwitch; break;
        default: break;
    }
    _lgSurfaceDescriptor = LGSurfaceDescriptorV1MakeDefault(role, 1);
    const LGHostDefinition *definition = LGHostDefinitionForFilterType(filterType.UTF8String);
    NSString *prefix = definition ? [NSString stringWithUTF8String:definition->preferencePrefix] : nil;
    _lgSurfaceDescriptor.backgroundProfile = (uint32_t)LGSurfaceBackgroundProfileForHost(prefix);
    _lgSurfaceDescriptor.qualityTier = (uint32_t)LGSurfaceQualityTierForHost(prefix);
    _lgSurfaceDescriptor.boundsOriginX = 0.0f;
    _lgSurfaceDescriptor.boundsOriginY = 0.0f;
    _lgSurfaceDescriptor.boundsWidth = fmaxf(0.0f, (float)CGRectGetWidth(frame));
    _lgSurfaceDescriptor.boundsHeight = fmaxf(0.0f, (float)CGRectGetHeight(frame));
    _lgSurfaceDescriptor.maskSource = (uint32_t)LGSurfaceMaskSourceLayerCornerRadius;
    _lgSurfaceDescriptor.geometrySpace = (uint32_t)LGSurfaceGeometryHostLocal;
    _lgSurfaceDescriptor.maskOriginX = 0.0f;
    _lgSurfaceDescriptor.maskOriginY = 0.0f;
    _lgSurfaceDescriptor.maskWidth = _lgSurfaceDescriptor.boundsWidth;
    _lgSurfaceDescriptor.maskHeight = _lgSurfaceDescriptor.boundsHeight;
    if (_lgSurfaceDescriptor.boundsWidth > 0.0f &&
        _lgSurfaceDescriptor.boundsHeight > 0.0f)
        _lgSurfaceDescriptor.flags |= LGSurfaceDescriptorGeometryValid;
    _lgSurfaceDescriptor.shapeKind = role == LGSurfaceRoleClock
        ? (uint32_t)LGSurfaceShapeGlyph : (uint32_t)LGSurfaceShapeRectangle;
    _lgSurfaceDescriptorInitialized = YES;
    static atomic_uint idCounter = 0;
    _lgId = atomic_fetch_add(&idCounter, 1) + 1;
    if (groupName.length) {
        _lgGroupName = [groupName copy];
    } else {
        static uint32_t salt = 0;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ salt = arc4random(); });
        _lgGroupName = [NSString stringWithFormat:@"dylv.liquidglass.p%d.%08x.g%u",
                                                  getpid(), salt, _lgId];
    }
    self.userInteractionEnabled = NO;
    self.backgroundColor        = [UIColor clearColor];
    self.opaque                 = NO;

    self.autoresizingMask       = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    LGEnsureFilterRefreshObserver();
    [sLGAllGlasses addObject:self];
    LGEnsureMotionHighlights();
    [sLGMotionGlasses addObject:self];
    [self applyFilters];
    return self;
}

- (void)dealloc {
    [sLGAllGlasses removeObject:self];
    [sLGMotionGlasses removeObject:self];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self applyFilters];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
        _filterAttached = NO;
        [self applyFilters];
        [self updateSpecular];
        }
}

- (NSNumber *)lgSpecularEnabledOverride {
    return objc_getAssociatedObject(self, kLGSpecularEnabledOverrideKey);
}

- (void)setLgSpecularEnabledOverride:(NSNumber *)override {
    NSNumber *previous = self.lgSpecularEnabledOverride;
    if ((previous == override) || [previous isEqualToNumber:override]) return;
    objc_setAssociatedObject(self, kLGSpecularEnabledOverrideKey, [override copy],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self updateSpecular];
}

- (void)setBounds:(CGRect)bounds {
    [super setBounds:bounds];
    [self lgRefreshSurfaceGeometryIfNeeded];
}

- (void)setFrame:(CGRect)frame {
    [super setFrame:frame];
    [self lgRefreshSurfaceGeometryIfNeeded];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self lgRefreshSurfaceGeometryIfNeeded];
    [self applyFilters];
    [self updateSpecular];
}

- (void)updateNativeBlurOverlayWithRadius:(CGFloat)radius {
    if (radius <= 0.0) {
        [_nativeBlurView removeFromSuperview];
        _nativeBlurView = nil;
        _nativeBlurRadius = 0.0;
        return;
    }

    if (!_nativeBlurView) {
        Class blurClass = NSClassFromString(@"LGSettingsLowBlurView");
        if (!blurClass) return;
        _nativeBlurView = [[blurClass alloc] initWithFrame:self.bounds];
        _nativeBlurView.userInteractionEnabled = NO;
        [self insertSubview:_nativeBlurView atIndex:0];
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _nativeBlurView.frame = self.bounds;
    _nativeBlurView.layer.cornerRadius = self.layer.cornerRadius;
    _nativeBlurView.layer.cornerCurve = self.layer.cornerCurve;
    _nativeBlurView.clipsToBounds = YES;
    if (fabs(_nativeBlurRadius - radius) > 0.001) {
        @try { [_nativeBlurView setValue:@(radius) forKey:@"lgBlurRadius"]; }
        @catch (__unused NSException *exception) {}
        _nativeBlurRadius = radius;
    }
    [CATransaction commit];
}

- (void)setLgShapeRect:(CGRect)rect {
    if (CGRectEqualToRect(_lgShapeRect, rect)) return;
    _lgShapeRect = rect;
    [self lgRefreshSurfaceGeometryIfNeeded];
    if (LGHostIdentifierForFilterType(_lgFilterType.UTF8String) ==
        LGHostIdentifierKeyboard) {
        _filterAttached = NO;
        [self applyFilters];
    }
    [self updateSpecular];
}

- (void)setLgShapeCornerRadius:(CGFloat)radius {
    if (fabs(_lgShapeCornerRadius - radius) < 0.01) return;
    _lgShapeCornerRadius = radius;
    [self lgRefreshSurfaceGeometryIfNeeded];
    if (LGHostIdentifierForFilterType(_lgFilterType.UTF8String) ==
        LGHostIdentifierKeyboard) {
        _filterAttached = NO;
        [self applyFilters];
    }
    [self updateSpecular];
}

- (void)updateSpecular {
    if (CGRectIsEmpty(self.bounds)) return;

    BOOL hasShape = !CGRectIsNull(_lgShapeRect) && !CGRectIsEmpty(_lgShapeRect);
    CGRect shapeRect = hasShape ? _lgShapeRect : self.bounds;
    CGFloat shapeRadius = hasShape ? _lgShapeCornerRadius
                                   : self.layer.cornerRadius;

    NSNumber *override = self.lgSpecularEnabledOverride;
    BOOL enabled = override ? override.boolValue
                            : LGSpecularEnabledForFilterType(_lgFilterType);
    const LGHostDefinition *host = LGHostDefinitionForFilterType(_lgFilterType.UTF8String);
    if (host == &kLGHostRegistry[LGHostIdentifierPrefsButtonCandidate]) {
        [_specularLayer removeFromSuperlayer];
        _specularLayer = nil;
        _specularMask = nil;
        [_edge removeFromSuperlayer];
        _edge = nil;
        return;
    }
    if (host == &kLGHostRegistry[LGHostIdentifierClock]) return;
    if (!enabled && !_specularLayer) return;

    if (!_edge) {
        _edge = [CAShapeLayer layer];
        _edge.backgroundColor = UIColor.clearColor.CGColor;
        _edge.borderWidth = kLGGlassEdgeWidth;
        [self.layer addSublayer:_edge];
    }

    CGFloat maxAlpha = 0.35;
    if (host) {
        NSString *prefix = [NSString stringWithUTF8String:host->preferencePrefix];
        id value = prefix.length
            ? LGGlassPreferenceValue([prefix stringByAppendingString:@".SpecularOpacity"])
            : nil;
        if ([value respondsToSelector:@selector(doubleValue)])
            maxAlpha = [value doubleValue];
        else if (host->specularOpacity > 0.001f)
            maxAlpha = host->specularOpacity;
    }
    maxAlpha = fmax(0.0, fmin(1.0, maxAlpha));

    if (!_specularLayer) {
        _specularLayer = [CAGradientLayer layer];
        _specularLayer.locations = @[@0.0, @0.12, @0.34, @0.66, @0.88, @1.0];
        _specularMask = [CAShapeLayer layer];
        _specularMask.backgroundColor = UIColor.clearColor.CGColor;
        _specularMask.borderColor = UIColor.blackColor.CGColor;
        _specularMask.borderWidth = 1.0;
        _specularLayer.mask = _specularMask;
        [self.layer addSublayer:_specularLayer];
    }
    if (fabs(_appliedSpecularOpacity - maxAlpha) > 0.001) {
        id clear = (id)UIColor.clearColor.CGColor;
        _specularLayer.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:maxAlpha * 0.28].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:maxAlpha * 0.10].CGColor,
            clear, clear,
            (id)[UIColor colorWithWhite:0.0 alpha:maxAlpha * 0.04].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:maxAlpha * 0.12].CGColor
        ];
        _appliedSpecularOpacity = maxAlpha;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _specularLayer.hidden = !enabled;
    _specularLayer.frame = shapeRect;
    UIColor *edgeColor = [UIColor.separatorColor colorWithAlphaComponent:0.16];
    if (@available(iOS 13.0, *))
        edgeColor = [edgeColor resolvedColorWithTraitCollection:self.traitCollection];
    _edge.hidden = NO;
    _edge.frame = shapeRect;
    _edge.cornerRadius = shapeRadius;
    _edge.cornerCurve = self.layer.cornerCurve;
    _edge.borderWidth = kLGGlassEdgeWidth;
    _edge.borderColor = edgeColor.CGColor;

    _specularMask.frame = CGRectMake(0.0, 0.0, CGRectGetWidth(shapeRect),
                                     CGRectGetHeight(shapeRect));
    _specularMask.cornerRadius = shapeRadius;
    _specularMask.cornerCurve = self.layer.cornerCurve;
    _specularMask.borderWidth = 1.0;
    [CATransaction commit];
    [self applySpecularAngle:sLGSpecularAngle];
}

- (void)applySpecularAngle:(CGFloat)angle {
    if (!_specularLayer) return;
    CGFloat dx = cos(angle) * 0.5;
    CGFloat dy = sin(angle) * 0.5;
    _specularLayer.startPoint = CGPointMake(0.5 + dx, 0.5 + dy);
    _specularLayer.endPoint = CGPointMake(0.5 - dx, 0.5 - dy);
}

- (LGSurfaceDescriptorV1)lgSurfaceDescriptor {
    @synchronized(self) { return _lgSurfaceDescriptor; }
}

/* Copy-only geometry observation. A query must not invent an owner or a
 * synthetic generation: an unsynchronized layout is rejected until its producer
 * or owned UIView lifecycle commits the geometry. Producer-owned masks stay owned. */
- (LGSurfaceDescriptorV1)lgLiveGeometryFromDescriptor:(LGSurfaceDescriptorV1)value {
    CGRect bounds = self.bounds;
    value.boundsOriginX = (float)CGRectGetMinX(bounds);
    value.boundsOriginY = (float)CGRectGetMinY(bounds);
    value.boundsWidth = (float)CGRectGetWidth(bounds);
    value.boundsHeight = (float)CGRectGetHeight(bounds);
    BOOL producerMask = value.maskSource == LGSurfaceMaskSourceTextMask ||
                        value.maskSource == LGSurfaceMaskSourceImageAlpha ||
                        (value.maskSource == LGSurfaceMaskSourceExplicitPath &&
                         self.layer.mask && CGRectIsNull(_lgShapeRect));
    if (!producerMask) {
        BOOL explicitRect = !CGRectIsNull(_lgShapeRect) && !CGRectIsEmpty(_lgShapeRect);
        CGRect mask = explicitRect ? _lgShapeRect : bounds;
        CGFloat radius = explicitRect ? _lgShapeCornerRadius : self.layer.cornerRadius;
        value.maskOriginX = (float)CGRectGetMinX(mask);
        value.maskOriginY = (float)CGRectGetMinY(mask);
        value.maskWidth = (float)CGRectGetWidth(mask);
        value.maskHeight = (float)CGRectGetHeight(mask);
        value.cornerRadius = (float)radius;
        value.maskSource = explicitRect ? LGSurfaceMaskSourceExplicitRectangle
                                       : LGSurfaceMaskSourceLayerCornerRadius;
        value.geometrySpace = LGSurfaceGeometryHostLocal;
        if (value.shapeKind != LGSurfaceShapeCircle && value.shapeKind != LGSurfaceShapeCapsule)
            value.shapeKind = radius > 0.01 ? LGSurfaceShapeRoundedRectangle
                                           : LGSurfaceShapeRectangle;
    }
    value.flags &= ~LGSurfaceDescriptorGeometryValid;
    if (value.boundsWidth > 0.0f && value.boundsHeight > 0.0f &&
        value.maskWidth > 0.0f && value.maskHeight > 0.0f)
        value.flags |= LGSurfaceDescriptorGeometryValid;
    return value;
}

- (void)lgRefreshSurfaceGeometryIfNeeded {
    @synchronized(self) {
        if (!_lgSurfaceDescriptorInitialized) return;
        LGSurfaceDescriptorV1 value = [self lgLiveGeometryFromDescriptor:_lgSurfaceDescriptor];
        if (!LGSurfaceGeometryEqual(&_lgSurfaceDescriptor, &value))
            value.geometryGeneration = LGSurfaceGenerationNext(_lgSurfaceDescriptor.geometryGeneration);
        if (LGSurfaceDescriptorV1IsValid(&value)) _lgSurfaceDescriptor = value;
    }
}

- (LGSurfaceDescriptorV1)lgPresentationSurfaceDescriptorWithOwnerGroup:(uint32_t)ownerGroup
                                                          ownerGeneration:(uint64_t)ownerGeneration
                                                            nestingDepth:(uint32_t)nestingDepth
                                                     nestedMaterialPolicy:(LGSurfaceNestedMaterialPolicy)policy {
    @synchronized(self) {
        LGSurfaceDescriptorV1 value = [self lgLiveGeometryFromDescriptor:_lgSurfaceDescriptor];
        // These fields are query context; generation/group must match the stored binding.
        if (!LGSurfaceGeometryEqual(&_lgSurfaceDescriptor, &value) ||
            value.captureOwnerGeneration != ownerGeneration ||
            value.captureOwnerGroup != ownerGroup) {
            value.version = 0; // fail closed: no stale-owner or uncommitted-geometry laundering
            return value;
        }
        value.nestingDepth = nestingDepth;
        value.nestedMaterialPolicy = (uint32_t)policy;
        if (_filterAttached) value.flags &= ~LGSurfaceDescriptorNativeFallback;
        else value.flags |= LGSurfaceDescriptorNativeFallback;
        return value;
    }
}

- (BOOL)lgUpdateSurfaceDescriptor:(LGSurfaceDescriptorV1)descriptor {
    if (!LGSurfaceDescriptorV1IsValid(&descriptor)) return NO;
    @synchronized(self) {
        if (!LGSurfaceDescriptorCanBindHostGeneration(
                &_lgSurfaceDescriptor, _lgSurfaceDescriptorInitialized && _lgSurfaceDescriptorHasHostBinding,
                &descriptor)) return NO;
        _lgSurfaceDescriptor = descriptor;
        _lgSurfaceDescriptorInitialized = YES;
        _lgSurfaceDescriptorHasHostBinding = YES;
    }
    return YES;
}

- (BOOL)lgSetSurfaceProfile:(LGSurfaceBackgroundProfile)profile qualityTier:(LGSurfaceQualityTier)qualityTier {
    if ((uint32_t)profile >= (uint32_t)LGSurfaceBackgroundProfileCount ||
        (uint32_t)qualityTier >= (uint32_t)LGSurfaceQualityTierCount) return NO;
    @synchronized(self) {
        if (_lgSurfaceDescriptorInitialized &&
            (_lgSurfaceDescriptor.backgroundProfile != (uint32_t)profile ||
             _lgSurfaceDescriptor.qualityTier != (uint32_t)qualityTier)) {
            _lgSurfaceDescriptor.backgroundProfile = (uint32_t)profile;
            _lgSurfaceDescriptor.qualityTier = (uint32_t)qualityTier;
            if (_lgSurfaceDescriptor.appearanceGeneration != UINT64_MAX)
                _lgSurfaceDescriptor.appearanceGeneration++;
        }
    }
    return YES;
}

- (void)lgSyncSurfaceRendererHealth:(BOOL)ready {
    @synchronized(self) {
        if (ready) _lgSurfaceDescriptor.flags &= ~LGSurfaceDescriptorNativeFallback;
        else _lgSurfaceDescriptor.flags |= LGSurfaceDescriptorNativeFallback;
        _lgSurfaceDescriptor.flags |= LGSurfaceDescriptorEnabled;
    }
}

- (void)lgSurfaceRendererWillRetry { [self lgSyncSurfaceRendererHealth:NO]; }

- (void)lgBindStockMaterial:(UIView *)material {
    if (!material || self.superview != material.superview) return;
    if (_stockMaterialView != material) {
        _stockMaterialView = material;
        _stockMaterialRequestedHidden = material.hidden;
        _stockGlassOriginalHidden = self.hidden;
        _stockGlassOriginalAlpha = self.alpha;
        _stockAlphaCaptured = YES;
    }
    [self lgApplyStockHealth];
}

- (void)lgApplyStockHealth {
    UIView *material = _stockMaterialView;
    if (!material) return;
    BOOL requestedHidden = _stockMaterialRequestedHidden;
    if (_filterAttached && self.superview == material.superview) {
        LGSetStockMaterialHiddenInternally(material, YES);
        self.hidden = _stockGlassOriginalHidden || requestedHidden;
        self.alpha = 1.0;
    } else {
        LGSetStockMaterialHiddenInternally(material, requestedHidden);
        self.hidden = YES;
        if (_stockAlphaCaptured) self.alpha = _stockGlassOriginalAlpha;
    }
}

- (void)lgSetStockMaterialRequestedHidden:(BOOL)hidden {
    if (!_stockMaterialView) return;
    _stockMaterialRequestedHidden = hidden;
    LGSetStockMaterialHiddenInternally(_stockMaterialView,
                                       _filterAttached ? YES : hidden);
    self.hidden = _filterAttached
        ? (_stockGlassOriginalHidden || hidden) : YES;
}

- (void)lgRestoreStockMaterial {
    if (_stockMaterialView)
        LGSetStockMaterialHiddenInternally(_stockMaterialView,
                                            _stockMaterialRequestedHidden);
    if (_stockAlphaCaptured) self.alpha = _stockGlassOriginalAlpha;
    self.hidden = _stockGlassOriginalHidden;
    _stockMaterialView = nil;
    _stockAlphaCaptured = NO;
}

- (void)lgStockMaterialVisibilityDidRequest:(BOOL)hidden {
    [self lgSetStockMaterialRequestedHidden:hidden];
}

- (void)applyFilters {
    [self lgRefreshSurfaceGeometryIfNeeded];
    BOOL wasAttached = _filterAttached;
    _filterAttached = NO;
    [self lgSyncSurfaceRendererHealth:NO];
    if (wasAttached) [self lgApplyStockHealth];
    CALayer *layer = self.layer;
    Class backdropCls = NSClassFromString(@"CABackdropLayer");
    if (!backdropCls || ![layer isKindOfClass:backdropCls]) {
        _filterAttached = NO;
        [self lgSyncSurfaceRendererHealth:NO];
        [self lgApplyStockHealth];
        if (self.lgFilterHealthHandler) self.lgFilterHealthHandler(NO);
        if (!backdropCls) sblog("CA filter unavailable: no CABackdropLayer");
        return;
    }

    @try {

        if (!_backdropConfigured) {
            // these private flags keep capture in render server space
            [layer setValue:@NO  forKey:@"layerUsesCoreImageFilters"];
            [layer setValue:@NO forKey:@"windowServerAware"];
            [layer setValue:_lgGroupName forKey:@"groupName"];
            [layer setValue:@"dylv.liquidglass" forKey:@"groupNamespace"];

            [layer setValue:@YES forKey:@"ignoresScreenClip"];
            _backdropConfigured = YES;
        }

        CGFloat wantScale;
        enum LGHostIdentifier hostIdentifier =
            LGHostIdentifierForFilterType(_lgFilterType.UTF8String);
        if (hostIdentifier == LGHostIdentifierClock) {
            wantScale = kLGClockCaptureScale;
        } else if (hostIdentifier == LGHostIdentifierCoverSheet ||
                   hostIdentifier == LGHostIdentifierTabBar ||
                   hostIdentifier == LGHostIdentifierTabBarSelection) {
            wantScale = 1.0;
        } else {
            wantScale = LGUsesPrefsControlCaptureScale(_lgFilterType)
                ? kLGPrefsControlScale : LGScaleForSize(self.bounds.size);
        }
        CGFloat wantZoom = _lgBackdropZoom > 0.0 ? _lgBackdropZoom : 1.0;
        BOOL zoomRelevant = fabs(wantZoom - 1.0) > 0.001 || _appliedBackdropZoom > 0.0;
        if (zoomRelevant && fabs(wantZoom - _appliedBackdropZoom) > 0.001) {
            _appliedBackdropZoom = wantZoom;
            @try { [layer setValue:@(wantZoom) forKey:@"zoom"]; }
            @catch (__unused NSException *exception) {}
            LGLog(@"glass#%u zoom type=%@ want=%.3f readback=%@", _lgId,
                  _lgFilterType ?: @"default", wantZoom,
                  [layer valueForKey:@"zoom"] ?: @"<none>");
        }

        if (fabs(wantScale - _appliedScale) > 0.02) {
            [layer setValue:@(wantScale) forKey:@"scale"];
            _appliedScale = wantScale;
        }

        NSString *wantType = [self lgEffectiveFilterType];
        NSArray *existing = layer.filters;
        Class filterCls = NSClassFromString(@"CAFilter");
        [self updateNativeBlurOverlayWithRadius:
            LGNativeBlurRadiusForFilterType(_lgFilterType ?: wantType)];

        if (_filterAttached && existing.count == 1) {
            NSString *type = nil;
            @try { type = [existing.firstObject valueForKey:@"type"]; } @catch (...) {}
            if ([type isEqualToString:wantType]) {
                [self lgApplyStockHealth];
                if (self.lgFilterHealthHandler) self.lgFilterHealthHandler(YES);
                return;
            }
        }
        if (!filterCls) {
            sblog("CAFilter unavailable; preserve native stock surface");
            [self lgApplyStockHealth];
            if (self.lgFilterHealthHandler) self.lgFilterHealthHandler(NO);
            return;
        }

        id glassFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, NSSelectorFromString(@"filterWithType:"), wantType);
        if (!glassFilter) {
            LGLog(@"glass#%u filter creation failed; native stock remains", _lgId);
            [self lgApplyStockHealth];
            if (self.lgFilterHealthHandler) self.lgFilterHealthHandler(NO);
            return;
        }

        if (LGNeedsGaussianIdentityFallback()) {
            @try { [glassFilter setValue:@1.0 forKey:@"inputRadius"]; }
            @catch (...) {}
        }

        layer.filters = @[glassFilter];
        id installed = layer.filters.count == 1 ? layer.filters.firstObject : nil;
        NSString *installedType = nil;
        @try { installedType = [installed valueForKey:@"type"]; }
        @catch (__unused NSException *exception) {}
        _filterAttached = installed && [installedType isEqualToString:wantType];
        [self lgSyncSurfaceRendererHealth:_filterAttached];
        [self lgApplyStockHealth];
        if (self.lgFilterHealthHandler) self.lgFilterHealthHandler(_filterAttached);
        if (_filterAttached)
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"LGLiveBackdropViewFilterDidAttach" object:self];
    } @catch (NSException *e) {
        layer.filters = @[];
        _filterAttached = NO;
        [self lgSyncSurfaceRendererHealth:NO];
        [self lgApplyStockHealth];
        if (self.lgFilterHealthHandler) self.lgFilterHealthHandler(NO);
        sblog("applyFilters exception: %s", e.reason.UTF8String);
    }
}

- (void)reapplyFilterForParameterReload {

    _parameterRefreshVariant = !_parameterRefreshVariant;

    _appliedScale = -1.0;
    [self applyFilters];
    [self updateSpecular];
    [self.layer setNeedsDisplay];
    [_specularLayer setNeedsDisplay];
}

- (void)lgInvalidateFilterContents {
    _parameterRefreshVariant = !_parameterRefreshVariant;
    _filterAttached = NO;
    [self applyFilters];
    [self.layer setNeedsDisplay];
}

- (BOOL)lgFilterAttached {
    return _filterAttached;
}

@end

#pragma mark - generic host injection

static CGRect LGOutsetFrame(CGRect mf, UIEdgeInsets outset) {
    return CGRectMake(mf.origin.x - outset.left,
                      mf.origin.y - outset.top,
                      mf.size.width  + outset.left + outset.right,
                      mf.size.height + outset.top  + outset.bottom);
}

void LGInjectGlassIntoMaterialGroupType(UIView *mat, const void *assocKey,
                                        UIEdgeInsets outset, CGFloat cornerRadius,
                                        NSString *groupName, NSString *filterType) {
    UIView *parent = mat.superview;
    if (!parent) return;

    CGRect gf = LGOutsetFrame(mat.frame, outset);

    LGLiveBackdropView *glass = objc_getAssociatedObject(mat, assocKey);
    if (!glass) {
        glass = [[LGLiveBackdropView alloc] initWithFrame:gf groupName:groupName filterType:filterType];
        [glass lgBindStockMaterial:mat];
        __weak LGLiveBackdropView *weakGlass = glass;
        UIView *stockMaterial = mat;
        const void *savedAssociationKey = assocKey;
        for (NSNumber *delay in @[ @1.5, @3.0, @5.0, @8.0, @12.0 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                LGLiveBackdropView *retryGlass = weakGlass;
                if (!retryGlass || !stockMaterial.window ||
                    objc_getAssociatedObject(stockMaterial, savedAssociationKey) != retryGlass)
                    return;
                [retryGlass applyFilters];
            });
        }
        [parent insertSubview:glass aboveSubview:mat];
        objc_setAssociatedObject(mat, assocKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != parent) [parent insertSubview:glass aboveSubview:mat];
    [glass lgBindStockMaterial:mat];
    if (!glass.lgFilterAttached) {
        glass.hidden = YES;
        [glass applyFilters];
    }
    CGFloat radius = (cornerRadius >= 0.0) ? cornerRadius : mat.layer.cornerRadius;
    if (!CGRectEqualToRect(glass.frame, gf))          glass.frame              = gf;
    if (fabs(glass.layer.cornerRadius - radius) > 0.5) {
        glass.layer.cornerRadius = radius;
        [glass updateSpecular];
        [glass applyFilters];
    }
    glass.layer.cornerCurve   = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;

    objc_setAssociatedObject(glass, kLGOutsetKey, [NSValue valueWithUIEdgeInsets:outset],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(glass, kLGRadiusKey, @(cornerRadius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [glass lgApplyStockHealth];
}

static void LGSyncGlassGeometry(UIView *mat, const void *assocKey,
                                UIEdgeInsets outset, CGFloat cornerRadius);

void LGResyncGlassGeometry(UIView *mat, const void *assocKey) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(mat, assocKey);
    if (!glass) return;
    [glass lgApplyStockHealth];
    NSValue *ov  = objc_getAssociatedObject(glass, kLGOutsetKey);
    NSNumber *rv = objc_getAssociatedObject(glass, kLGRadiusKey);
    LGSyncGlassGeometry(mat, assocKey, ov ? ov.UIEdgeInsetsValue : UIEdgeInsetsZero,
                        rv ? rv.doubleValue : -1.0);
}

static void LGSyncGlassGeometry(UIView *mat, const void *assocKey,
                                UIEdgeInsets outset, CGFloat cornerRadius) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(mat, assocKey);
    if (!glass) return;
    CGRect gf = LGOutsetFrame(mat.frame, outset);
    CGFloat radius = (cornerRadius >= 0.0) ? cornerRadius : mat.layer.cornerRadius;

    if (!CGRectEqualToRect(glass.frame, gf)) {
        glass.frame = gf;
    }
    if (fabs(glass.layer.cornerRadius - radius) > 0.5) {
        glass.layer.cornerRadius = radius;
        [glass updateSpecular];
        [glass applyFilters];
    }
    [glass lgApplyStockHealth];
}

void LGRemoveGlassFromMaterial(UIView *mat, const void *assocKey) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(mat, assocKey);
    if (!glass) return;
    objc_setAssociatedObject(mat, assocKey, nil, OBJC_ASSOCIATION_ASSIGN);
    lgUntrackGlass(glass);
    [glass lgRestoreStockMaterial];
    [glass removeFromSuperview];
}

BOOL LGMaterialHasGlass(UIView *mat, const void *assocKey) {
    return objc_getAssociatedObject(mat, assocKey) != nil;
}
