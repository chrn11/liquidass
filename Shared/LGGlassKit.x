#import "LGGlassKit.h"
#import "LGLiveBackdropView.h"
#import "LGHostRegistry.h"
#import "LGSurfaceDiagnostics.h"
#import "LGSurfaceDiagnosticIO.h"
#import <objc/runtime.h>

#pragma mark - class / ancestry helpers

BOOL hasAncestorOfClassName(UIView *v, NSString *clsName) {
    Class cls = NSClassFromString(clsName);
    if (!cls) return NO;
    for (UIView *cur = v; cur; cur = cur.superview)
        if ([cur isKindOfClass:cls]) return YES;
    return NO;
}

BOOL ancestorNameContains(UIView *v, NSString *sub) {
    for (UIView *cur = v; cur; cur = cur.superview)
        if ([NSStringFromClass(cur.class) containsString:sub]) return YES;
    return NO;
}

BOOL isExactClass(UIView *v, NSString *name) {
    return v && [NSStringFromClass(v.class) isEqualToString:name];
}

#pragma mark - per-host enable prefs

BOOL LGProcessMatchesExclusionList(id list) {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier.lowercaseString ?: @"";
    if ([list isKindOfClass:NSArray.class]) {
        for (id value in (NSArray *)list)
            if ([value isKindOfClass:NSString.class] &&
                [bundleID isEqualToString:[value lowercaseString]]) return YES;
        return NO;
    }
    if (![list isKindOfClass:NSString.class] || ![list length]) return NO;
    NSString *executable =
        NSBundle.mainBundle.executablePath.lastPathComponent.lowercaseString ?: @"";
    NSString *processName = NSProcessInfo.processInfo.processName.lowercaseString ?: @"";
    NSCharacterSet *separators =
        [NSCharacterSet characterSetWithCharactersInString:@"\n,;"];
    for (NSString *rawEntry in [(NSString *)list componentsSeparatedByCharactersInSet:separators]) {
        NSString *entry = [rawEntry stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
        if (!entry.length || [entry hasPrefix:@"#"]) continue;
        if ([entry isEqualToString:bundleID] ||
            [entry isEqualToString:executable] ||
            [entry isEqualToString:processName]) return YES;
    }
    return NO;
}

BOOL lgHostEnabled(NSString *prefix) {
    if (!prefix.length) return YES;
    id global = LGGlassPreferenceValue(@"Global.Enabled");
    if (![prefix isEqualToString:@"Global"] && [global isKindOfClass:[NSNumber class]] && ![global boolValue])
        return NO;
    id value = LGGlassPreferenceValue([prefix stringByAppendingString:@".Enabled"]);
    if (!value && [prefix isEqualToString:@"OpenFolder"])
        value = LGGlassPreferenceValue(@"FolderOpen.Enabled");
    if (!value && [prefix isEqualToString:@"AppLibSearch"])
        value = LGGlassPreferenceValue(@"AppLibrary.Search.Enabled");

    if (![value isKindOfClass:[NSNumber class]]) {
        static NSDictionary<NSString *, NSString *> *legacyPrefixes;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            legacyPrefixes = @{
                @"OpenFolder":   @"FolderOpen",
                @"AppLibSearch": @"AppLibrary.Search",
                @"Passcode":     @"Lockscreen.Passcode",
                @"Clock":        @"Lockscreen.Clock",
                @"QuickActions": @"LockscreenQuickActions",
            };
        });
        NSString *legacy = legacyPrefixes[prefix];
        if (legacy) value = LGGlassPreferenceValue(
            [legacy stringByAppendingString:@".Enabled"]);
    }
    if ([value isKindOfClass:[NSNumber class]]) return [value boolValue];

    if ([prefix isEqualToString:@"AppIcons"]) return NO;
    return YES;
}

#pragma mark - uniform injection registry

@interface LGGlassRec : NSObject
@property (nonatomic, copy) NSString *prefix;
@property (nonatomic, weak) UIView *glass;
@property (nonatomic, weak) UIView *material;
@property (nonatomic, assign) BOOL hasMaterialOwner;
@property (nonatomic, assign) uint64_t hostGeneration;
@property (nonatomic, assign) uint64_t diagnosticIdentifier;
@end
@implementation LGGlassRec @end

static uint64_t LGGlassKitNextHostGeneration(void) {
    static uint64_t generation = 0;
    @synchronized([LGGlassRec class]) {
        if (generation < UINT64_MAX) generation++;
        return generation;
    }
}

void *kGlassKey = &kGlassKey;

static NSMapTable<UIView *, LGGlassRec *> *sGlassRecs;
static NSMapTable<UIView *, NSString *> *sSuppressed;
static NSMapTable<UIView *, NSNumber *> *sSuppressedOriginalHidden;
static NSMutableArray<void (^)(void)> *sReloadHandlers;

@interface LGMaterialHostRoute : NSObject
@property (nonatomic, copy) NSString *prefix;
@property (nonatomic) NSInteger priority;
@property (nonatomic, copy) LGMaterialHostMatcher matcher;
@property (nonatomic) UIEdgeInsets outset;
@property (nonatomic, copy) LGMaterialHostCornerRadiusProvider cornerRadiusProvider;
@property (nonatomic, copy) NSString *groupName;
@property (nonatomic, copy) LGMaterialHostPostInstall postInstall;
@end
@implementation LGMaterialHostRoute @end
static NSMutableArray<LGMaterialHostRoute *> *sMaterialHostRoutes;

void lgObservePreferenceReload(void (^handler)(void)) {
    if (!handler) return;
    if (!sReloadHandlers) sReloadHandlers = [NSMutableArray array];
    [sReloadHandlers addObject:[handler copy]];
}

static uint32_t LGGlassMaterialNestingDepth(UIView *material,
                                                  LGLiveBackdropView *glass) {
    UIView *ancestor = material ? material.superview : glass.superview;
    uint32_t depth = 0;
    for (; ancestor; ancestor = ancestor.superview) {
        if (isExactClass(ancestor, @"MTMaterialView") && depth < UINT32_MAX)
            depth++;
    }
    return depth;
}

void lgTrackGlass(UIView *glass, NSString *prefix, UIView *material) {
    if (!NSThread.isMainThread || !glass || !prefix.length) return;
    if (![glass isKindOfClass:LGLiveBackdropView.class]) {
        // Legacy helpers such as the fullscreen Passcode UIView tint participate
        // in disable/restore lifecycle, not in the glass descriptor protocol.
        if (!sGlassRecs) sGlassRecs = [NSMapTable weakToStrongObjectsMapTable];
        LGGlassRec *helper = [sGlassRecs objectForKey:glass] ?: [LGGlassRec new];
        helper.glass = glass;
        helper.prefix = prefix;
        helper.material = material;
        helper.hasMaterialOwner = material != nil;
        [sGlassRecs setObject:helper forKey:glass];
        return;
    }
    LGLiveBackdropView *glassView = (LGLiveBackdropView *)glass;
    enum LGHostIdentifier boundHost = LGHostIdentifierForFilterType(glassView.lgFilterType.UTF8String);
    const LGHostDefinition *prefixHost = LGHostDefinitionForPreferencePrefix(prefix.UTF8String);
    if (boundHost >= LGHostIdentifierCount || prefixHost != &kLGHostRegistry[boundHost]) return;
    if (!sGlassRecs) sGlassRecs = [NSMapTable weakToStrongObjectsMapTable];
    LGGlassRec *existing = [sGlassRecs objectForKey:glassView];
    if (existing) {
        UIView *previousMaterial = existing.material;
        BOOL ownerChanged = previousMaterial != material ||
                            existing.hasMaterialOwner != (material != nil);
        uint64_t hostGeneration = existing.hostGeneration;
        if (!hostGeneration || ownerChanged)
            hostGeneration = LGGlassKitNextHostGeneration();
        LGSurfaceDescriptorV1 current = glassView.lgSurfaceDescriptor;
        LGSurfaceDescriptorV1 previous = current;
        current.hostGeneration = hostGeneration;
        enum LGHostIdentifier identifier =
            LGHostIdentifierForFilterType(glassView.lgFilterType.UTF8String);
        switch (identifier) {
            case LGHostIdentifierClock: current.role = LGSurfaceRoleClock; break;
            case LGHostIdentifierKeyboard: current.role = LGSurfaceRoleKeyboard; break;
            case LGHostIdentifierTabBarSelection: current.role = LGSurfaceRoleTabSelection; break;
            case LGHostIdentifierQuickActions:
            case LGHostIdentifierPrefsButton:
            case LGHostIdentifierPrefsButtonCandidate: current.role = LGSurfaceRoleButton; break;
            case LGHostIdentifierPrefsSlider: current.role = LGSurfaceRoleSlider; break;
            case LGHostIdentifierPrefsSwitch: current.role = LGSurfaceRoleSwitch; break;
            default: current.role = LGSurfaceRolePanel; break;
        }
        current.captureGroup = identifier < LGHostIdentifierCount
            ? (uint32_t)identifier : UINT32_MAX;
        if (identifier < LGHostIdentifierCount) {
            NSString *hostPrefix = [NSString stringWithUTF8String:kLGHostRegistry[identifier].preferencePrefix];
            current.backgroundProfile = (uint32_t)LGSurfaceBackgroundProfileForHost(hostPrefix);
            current.qualityTier = (uint32_t)LGSurfaceQualityTierForHost(hostPrefix);
        }
        if (!LGSurfaceAppearanceEqual(&previous, &current))
            current.appearanceGeneration = LGSurfaceGenerationNext(previous.appearanceGeneration);
        if (!ownerChanged && !current.captureOwnerGeneration) {
            current.captureOwnerGeneration = existing.hostGeneration;
            current.captureOwnerGroup = current.captureGroup;
        }
        if (ownerChanged) {
            current.captureOwnerGeneration = hostGeneration;
            current.captureOwnerGroup = current.captureGroup;
        }
        uint32_t depth = LGGlassMaterialNestingDepth(material, glassView);
        current.nestingDepth = depth;
        current.nestedMaterialPolicy = (uint32_t)LGSurfaceNestedMaterialPolicyFromDepth(depth);
        current.flags |= LGSurfaceDescriptorEnabled;
        if (glassView.lgFilterAttached)
            current.flags &= ~LGSurfaceDescriptorNativeFallback;
        else
            current.flags |= LGSurfaceDescriptorNativeFallback;
        if (ownerChanged) {
            if (!LGSurfaceDescriptorCanBindHostGeneration(
                    &previous, YES, &current)) {
                LGLog(@"descriptor-rebind rejected host=%@ previous-owner=%p next-owner=%p old-gen=%llu new-gen=%llu",
                      prefix, previousMaterial, material,
                      (unsigned long long)glassView.lgSurfaceDescriptor.captureOwnerGeneration,
                      (unsigned long long)current.captureOwnerGeneration);
                return;
            }
        }
        if (![glassView lgUpdateSurfaceDescriptor:current]) {
            LGLog(@"descriptor-update rejected host=%@ gen=%llu", prefix,
                  (unsigned long long)hostGeneration);
            return;
        }
        // Publish registry identity only after the descriptor accepted the owner.
        existing.prefix = prefix;
        existing.material = material;
        existing.hasMaterialOwner = material != nil;
        existing.hostGeneration = hostGeneration;
        [sGlassRecs setObject:existing forKey:glassView];
        return;
    }
    LGGlassRec *record = [LGGlassRec new];
    record.glass = glassView;
    record.material = material;
    record.hasMaterialOwner = material != nil;
    record.prefix = prefix;
    record.hostGeneration = LGGlassKitNextHostGeneration();
    record.diagnosticIdentifier = record.hostGeneration;
    LGSurfaceDescriptorV1 current = glassView.lgSurfaceDescriptor;
    const LGSurfaceDescriptorV1 previous = current;
    current.hostGeneration = record.hostGeneration;
    enum LGHostIdentifier identifier =
        LGHostIdentifierForFilterType(glassView.lgFilterType.UTF8String);
    switch (identifier) {
        case LGHostIdentifierClock: current.role = LGSurfaceRoleClock; break;
        case LGHostIdentifierKeyboard: current.role = LGSurfaceRoleKeyboard; break;
        case LGHostIdentifierTabBarSelection: current.role = LGSurfaceRoleTabSelection; break;
        case LGHostIdentifierQuickActions:
        case LGHostIdentifierPrefsButton:
        case LGHostIdentifierPrefsButtonCandidate: current.role = LGSurfaceRoleButton; break;
        case LGHostIdentifierPrefsSlider: current.role = LGSurfaceRoleSlider; break;
        case LGHostIdentifierPrefsSwitch: current.role = LGSurfaceRoleSwitch; break;
        default: current.role = LGSurfaceRolePanel; break;
    }
    current.captureGroup = identifier < LGHostIdentifierCount
        ? (uint32_t)identifier : UINT32_MAX;
    if (identifier < LGHostIdentifierCount) {
        NSString *hostPrefix = [NSString stringWithUTF8String:kLGHostRegistry[identifier].preferencePrefix];
        current.backgroundProfile = (uint32_t)LGSurfaceBackgroundProfileForHost(hostPrefix);
        current.qualityTier = (uint32_t)LGSurfaceQualityTierForHost(hostPrefix);
    }
    if (previous.captureOwnerGeneration && !LGSurfaceAppearanceEqual(&previous, &current))
        current.appearanceGeneration = LGSurfaceGenerationNext(previous.appearanceGeneration);
    current.captureOwnerGeneration = record.hostGeneration;
    current.captureOwnerGroup = current.captureGroup;
    uint32_t depth = LGGlassMaterialNestingDepth(material, glassView);
    current.nestingDepth = depth;
    current.nestedMaterialPolicy = (uint32_t)LGSurfaceNestedMaterialPolicyFromDepth(depth);
    current.flags |= LGSurfaceDescriptorEnabled;
    if (glassView.lgFilterAttached)
        current.flags &= ~LGSurfaceDescriptorNativeFallback;
    else
        current.flags |= LGSurfaceDescriptorNativeFallback;
    if (![glassView lgUpdateSurfaceDescriptor:current]) {
        LGLog(@"descriptor-bind failed host=%@ gen=%llu current-gen=%llu geo=%llu/%llu appearance=%llu/%llu interaction=%llu/%llu",
              prefix,
              (unsigned long long)current.hostGeneration,
              (unsigned long long)glassView.lgSurfaceDescriptor.hostGeneration,
              (unsigned long long)current.geometryGeneration,
              (unsigned long long)glassView.lgSurfaceDescriptor.geometryGeneration,
              (unsigned long long)current.appearanceGeneration,
              (unsigned long long)glassView.lgSurfaceDescriptor.appearanceGeneration,
              (unsigned long long)current.interactionGeneration,
              (unsigned long long)glassView.lgSurfaceDescriptor.interactionGeneration);
        return;
    }
    [sGlassRecs setObject:record forKey:glassView];
}

void lgUntrackGlass(UIView *glass) {
    if (!NSThread.isMainThread || !glass) return;
    [sGlassRecs removeObjectForKey:glass];
}

static dispatch_source_t sSurfaceDiagnosticTimer;
static dispatch_queue_t sSurfaceDiagnosticIOQueue;
static uint64_t sSurfaceDiagnosticEpoch, sSurfaceDiagnosticSerial;
static BOOL sSurfaceDiagnosticWriting;

static BOOL LGSurfaceDiagnosticsEnabled(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"] &&
           LGSurfaceDiagnosticsPreferenceEnabled(LGGlassPreferenceValue(LG_SURFACE_DIAGNOSTICS_PREF));
}

static void LGPublishSurfaceDiagnostics(void) {
    if (!NSThread.isMainThread || !LGSurfaceDiagnosticsEnabled() || sSurfaceDiagnosticWriting) return;
    LGSurfaceDiagnosticPacketV1 *packet = calloc(1, sizeof(*packet));
    if (!packet) return;
    packet->magic = LG_SURFACE_DIAGNOSTICS_MAGIC;
    packet->version = LG_SURFACE_DIAGNOSTICS_VERSION;
    packet->byteSize = sizeof(*packet);
    packet->capacity = LG_SURFACE_DIAGNOSTICS_CAPACITY;
    packet->producerPID = (uint32_t)getpid();
    packet->producerEpoch = sSurfaceDiagnosticEpoch;
    packet->serial = ++sSurfaceDiagnosticSerial;
    packet->monotonicMilliseconds = LGSurfaceDiagnosticMonotonicMilliseconds();
    packet->flags = LG_SURFACE_DIAGNOSTICS_ONLY;
    NSArray<UIView *> *glasses = [sGlassRecs.keyEnumerator.allObjects
        sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
            uint64_t x = [sGlassRecs objectForKey:a].diagnosticIdentifier;
            uint64_t y = [sGlassRecs objectForKey:b].diagnosticIdentifier;
            return x == y ? NSOrderedSame : (x < y ? NSOrderedAscending : NSOrderedDescending);
        }];
    for (UIView *candidate in glasses) {
        if (![candidate isKindOfClass:LGLiveBackdropView.class]) continue;
        LGLiveBackdropView *glass = (LGLiveBackdropView *)candidate;
        LGGlassRec *record = [sGlassRecs objectForKey:glass];
        if (!record || !record.diagnosticIdentifier || !glass.window || !lgHostEnabled(record.prefix) ||
            (record.hasMaterialOwner && !record.material)) continue;
        uint32_t host = (uint32_t)LGHostIdentifierForFilterType(glass.lgFilterType.UTF8String);
        if (host >= LGHostIdentifierCount) continue;
        uint32_t depth = LGGlassMaterialNestingDepth(record.material, glass);
        LGSurfaceDescriptorV1 value;
        if (record.material && objc_getAssociatedObject(record.material, kGlassKey) == glass) {
            // Exercise the owner/association-bound pure query only in diagnostics.
            LGMaterialSurfaceDescriptor snapshot = {0};
            if (!LGDescribeMaterialSurface(record.material, kGlassKey, &snapshot)) continue;
            value = snapshot.surface;
        } else {
            value = [glass lgPresentationSurfaceDescriptorWithOwnerGroup:host
                ownerGeneration:record.hostGeneration nestingDepth:depth
                nestedMaterialPolicy:LGSurfaceNestedMaterialPolicyFromDepth(depth)];
        }
        if (!LGSurfaceDescriptorV1IsValid(&value) || value.hostGeneration != record.hostGeneration ||
            value.captureOwnerGeneration != record.hostGeneration || value.captureGroup != host ||
            value.captureOwnerGroup != host) continue;
        if (packet->count == LG_SURFACE_DIAGNOSTICS_CAPACITY) {
            packet->flags |= LG_SURFACE_DIAGNOSTICS_TRUNCATED;
            break;
        }
        packet->entries[packet->count].surfaceIdentifier = record.diagnosticIdentifier;
        packet->entries[packet->count++].surface = value;
    }
    sSurfaceDiagnosticWriting = YES;
    dispatch_async(sSurfaceDiagnosticIOQueue, ^{
        BOOL wrote = LGSurfaceDiagnosticWriteAtomic(LG_SURFACE_DIAGNOSTICS_PATH, packet, sizeof(*packet));
        free(packet);
        if (wrote) CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR(LG_SURFACE_DIAGNOSTICS_NOTE), NULL, NULL, true);
        dispatch_async(dispatch_get_main_queue(), ^{ sSurfaceDiagnosticWriting = NO; });
    });
}

static void LGRefreshSurfaceDiagnosticPublisher(void) {
    if (!NSThread.isMainThread) return;
    if (!LGSurfaceDiagnosticsEnabled()) {
        if (sSurfaceDiagnosticTimer) dispatch_source_cancel(sSurfaceDiagnosticTimer);
        sSurfaceDiagnosticTimer = nil;
        if (sSurfaceDiagnosticIOQueue)
            dispatch_async(sSurfaceDiagnosticIOQueue, ^{ unlink(LG_SURFACE_DIAGNOSTICS_PATH); });
        return;
    }
    if (sSurfaceDiagnosticTimer) return;
    if (!sSurfaceDiagnosticIOQueue)
        sSurfaceDiagnosticIOQueue = dispatch_queue_create("dylv.liquidglass.diagnostic-writer", DISPATCH_QUEUE_SERIAL);
    // A new enable epoch must not be confused with the previous producer run.
    do { arc4random_buf(&sSurfaceDiagnosticEpoch, sizeof(sSurfaceDiagnosticEpoch)); }
    while (!sSurfaceDiagnosticEpoch);
    sSurfaceDiagnosticSerial = 0;
    sSurfaceDiagnosticTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(sSurfaceDiagnosticTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
        NSEC_PER_SEC, NSEC_PER_SEC / 5);
    dispatch_source_set_event_handler(sSurfaceDiagnosticTimer, ^{ LGPublishSurfaceDiagnostics(); });
    dispatch_resume(sSurfaceDiagnosticTimer);
}

BOOL LGDescribeMaterialSurface(UIView *material, const void *associationKey,
                               LGMaterialSurfaceDescriptor *outDescriptor) {
    if (outDescriptor) *outDescriptor = (LGMaterialSurfaceDescriptor){0};
    if (!NSThread.isMainThread || !material || !associationKey || !outDescriptor) return NO;
    id candidate = objc_getAssociatedObject(material, associationKey);
    if (![candidate isKindOfClass:LGLiveBackdropView.class]) return NO;
    LGLiveBackdropView *glass = (LGLiveBackdropView *)candidate;
    LGGlassRec *record = [sGlassRecs objectForKey:glass];
    if (!record || !record.hasMaterialOwner || record.material != material) return NO;
    // Query never mutates/binds; an unregistered or mismatched owner is not describable.
    enum LGHostIdentifier identifier = LGHostIdentifierForFilterType(glass.lgFilterType.UTF8String);
    if (identifier >= LGHostIdentifierCount) return NO;
    uint32_t depth = LGGlassMaterialNestingDepth(material, glass);
    LGSurfaceDescriptorV1 value = [glass lgPresentationSurfaceDescriptorWithOwnerGroup:(uint32_t)identifier
                                                                         ownerGeneration:record.hostGeneration
                                                                              nestingDepth:depth
                                                                     nestedMaterialPolicy:LGSurfaceNestedMaterialPolicyFromDepth(depth)];
    if (!LGSurfaceDescriptorV1IsValid(&value) ||
        value.hostGeneration != record.hostGeneration ||
        value.captureOwnerGeneration != record.hostGeneration ||
        value.captureGroup != (uint32_t)identifier ||
        value.captureOwnerGroup != (uint32_t)identifier) return NO;
    if (!LGSurfaceDescriptorV1IsValid(&value)) return NO;
    LGMaterialSurfaceDescriptor snapshot = {0};
    snapshot.associationKey = associationKey;
    snapshot.glass = glass;
    snapshot.material = material;
    snapshot.surface = value;
    *outDescriptor = snapshot;
    return YES;
}

void lgSuppressStock(UIView *v, NSString *prefix, BOOL setHidden) {
    if (!v || !prefix.length) return;
    if (!sSuppressed) sSuppressed = [NSMapTable weakToStrongObjectsMapTable];
    if (!sSuppressedOriginalHidden)
        sSuppressedOriginalHidden = [NSMapTable weakToStrongObjectsMapTable];

    NSString *existingPrefix = [sSuppressed objectForKey:v];
    if (!existingPrefix || ![existingPrefix isEqualToString:prefix])
        [sSuppressedOriginalHidden setObject:@(v.hidden) forKey:v];
    [sSuppressed setObject:[prefix copy] forKey:v];
    if (setHidden) v.hidden = YES;
}


LGLiveBackdropView *LGCreateRegisteredGlass(CGRect frame,
                                             NSString *groupName,
                                             NSString *prefix) {
    if (!prefix.length) return nil;
    NSString *filterType = LGFilterTypeForHostPrefix(prefix);
    if (!filterType) {
        LGLog(@"lifecycle rejected unknown host prefix=%@", prefix);
        return nil;
    }
    LGLiveBackdropView *glass = [[LGLiveBackdropView alloc]
        initWithFrame:frame groupName:groupName filterType:filterType];
    lgTrackGlass(glass, prefix, nil);
    return glass;
}

LGLiveBackdropView *LGInstallRegisteredGlassInMaterial(UIView *material,
                                                        const void *associationKey,
                                                        NSString *prefix,
                                                        UIEdgeInsets outset,
                                                        CGFloat cornerRadius,
                                                        NSString *groupName) {
    if (!material || !associationKey || !prefix.length) return nil;
    const LGHostDefinition *host =
        LGHostDefinitionForPreferencePrefix(prefix.UTF8String);
    if (!host) {
        LGLog(@"lifecycle rejected unknown host prefix=%@", prefix);
        LGRemoveGlassFromMaterial(material, associationKey);
        return nil;
    }
    if (!lgHostEnabled(prefix)) {
        LGRemoveGlassFromMaterial(material, associationKey);
        return nil;
    }

    NSString *filterType = [NSString stringWithUTF8String:host->filterType];
    LGLiveBackdropView *glass = objc_getAssociatedObject(material, associationKey);
    if (!glass) {
        LGInjectGlassIntoMaterialGroupType(material, associationKey, outset,
                                           cornerRadius, groupName, filterType);
        glass = objc_getAssociatedObject(material, associationKey);
    }
    if (!glass) return nil;
    lgTrackGlass(glass, prefix, material);
    if (!glass.lgFilterAttached) {
        // Keep one associated, hidden renderer alive so a later geometry/window
        // cycle or its bounded retry can recover without exposing a blank host.
        glass.hidden = YES;
        [glass applyFilters];
        if (!glass.lgFilterAttached) {
            [glass lgApplyStockHealth];
            LGLog(@"renderer-health host=%@ state=native-fallback-retry-pending material=%p",
                  prefix, material);
            return nil;
        }
    }
    lgTrackGlass(glass, prefix, material);
    return glass;
}

BOOL LGMaterialGlassReady(UIView *material, const void *associationKey) {
    if (!material || !associationKey) return NO;
    id candidate = objc_getAssociatedObject(material, associationKey);
    // Diagnostic metadata MUST NOT gate stock visibility. Preserve P0's
    // independent CA filter readback (which still is not final presentation).
    return [candidate isKindOfClass:LGLiveBackdropView.class] &&
           [(LGLiveBackdropView *)candidate lgFilterAttached];
}

void LGRegisterMaterialHost(NSString *prefix,
                            NSInteger priority,
                            LGMaterialHostMatcher matcher,
                            UIEdgeInsets outset,
                            LGMaterialHostCornerRadiusProvider cornerRadiusProvider,
                            NSString *groupName,
                            LGMaterialHostPostInstall postInstall) {
    if (!prefix.length || !matcher ||
        !LGHostDefinitionForPreferencePrefix(prefix.UTF8String)) {
        LGLog(@"router rejected invalid material host prefix=%@", prefix);
        return;
    }
    if (!sMaterialHostRoutes) sMaterialHostRoutes = [NSMutableArray array];
    for (LGMaterialHostRoute *route in sMaterialHostRoutes) {
        if ([route.prefix isEqualToString:prefix]) return;
    }
    LGMaterialHostRoute *route = [LGMaterialHostRoute new];
    route.prefix = prefix;
    route.priority = priority;
    route.matcher = [matcher copy];
    route.outset = outset;
    route.cornerRadiusProvider = [cornerRadiusProvider copy];
    route.groupName = groupName;
    route.postInstall = [postInstall copy];
    [sMaterialHostRoutes addObject:route];
    // priority makes one host own each material
    [sMaterialHostRoutes sortUsingComparator:^NSComparisonResult(LGMaterialHostRoute *a,
                                                                   LGMaterialHostRoute *b) {
        if (a.priority == b.priority) return [a.prefix compare:b.prefix];
        return a.priority > b.priority ? NSOrderedAscending : NSOrderedDescending;
    }];
}

static void lgRouteMaterialHost(UIView *material) {
    if (!material.window) {
        LGRemoveGlassFromMaterial(material, kGlassKey);
        return;
    }
    for (LGMaterialHostRoute *route in sMaterialHostRoutes) {
        if (!route.matcher(material)) continue;
        CGFloat radius = route.cornerRadiusProvider
            ? route.cornerRadiusProvider(material) : -1.0;
        LGLiveBackdropView *glass = LGInstallRegisteredGlassInMaterial(
            material, kGlassKey, route.prefix, route.outset, radius, route.groupName);
        if (glass && route.postInstall) route.postInstall(material, glass);
        return;
    }
}

static void lgReconcileInjectionsForDisable(void) {
    // Restore only stock views for which this module captured the prior state.
    if (sGlassRecs.count) {
        for (UIView *glass in sGlassRecs.keyEnumerator.allObjects) {
            LGGlassRec *r = [sGlassRecs objectForKey:glass];
            if (!r || lgHostEnabled(r.prefix)) continue;
            if (r.material) LGRemoveGlassFromMaterial(r.material, kGlassKey);
            else [glass removeFromSuperview];
            [sGlassRecs removeObjectForKey:glass];
        }
    }
    for (UIView *view in sSuppressed.keyEnumerator.allObjects) {
        NSString *prefix = [sSuppressed objectForKey:view];
        if (!prefix || lgHostEnabled(prefix)) continue;
        NSNumber *original = [sSuppressedOriginalHidden objectForKey:view];
        if (original) {
            view.hidden = original.boolValue;
            [sSuppressedOriginalHidden removeObjectForKey:view];
        }
        [sSuppressed removeObjectForKey:view];
    }
}

static void lgEnablePrefsReloadCallback(CFNotificationCenterRef c, void *o, CFStringRef n,
                                        const void *obj, CFDictionaryRef info) {
    LGLog(@"prefs Reload received; invalidating SpringBoard host-enable cache");
    LGInvalidateGlassPreferenceCache();

    dispatch_async(dispatch_get_main_queue(), ^{
        lgReconcileInjectionsForDisable();
        LGLog(@"prefs Reload reconciled material hosts; extraHandlers=%lu",
              (unsigned long)sReloadHandlers.count);
        for (UIView *candidate in sGlassRecs.keyEnumerator.allObjects) {
            if (![candidate isKindOfClass:LGLiveBackdropView.class]) continue;
            LGLiveBackdropView *tracked = (LGLiveBackdropView *)candidate;
            LGGlassRec *record = [sGlassRecs objectForKey:tracked];
            if (!record || !record.hostGeneration) continue;
            enum LGHostIdentifier host =
                LGHostIdentifierForFilterType(tracked.lgFilterType.UTF8String);
            if (host < LGHostIdentifierCount) {
                NSString *hostPrefix = [NSString stringWithUTF8String:kLGHostRegistry[host].preferencePrefix];
                [tracked lgSetSurfaceProfile:LGSurfaceBackgroundProfileForHost(hostPrefix)
                                 qualityTier:LGSurfaceQualityTierForHost(hostPrefix)];
            }
            [tracked applyFilters];
        }
        for (void (^handler)(void) in [sReloadHandlers copy]) handler();
        LGRefreshSurfaceDiagnosticPublisher();
    });
}

__attribute__((constructor)) static void lgGlassInitEnableObserver(void) {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, lgEnablePrefsReloadCallback, CFSTR("dylv.liquidassprefs/Reload"),
        NULL, CFNotificationSuspensionBehaviorCoalesce);
    dispatch_async(dispatch_get_main_queue(), ^{ LGRefreshSurfaceDiagnosticPublisher(); });
}

#pragma mark - shared material lifecycle

%hook MTMaterialView

- (void)didMoveToWindow {
    %orig;
    lgRouteMaterialHost((UIView *)self);
}

- (void)layoutSubviews { %orig; lgRouteMaterialHost((UIView *)self); }

- (void)setHidden:(BOOL)hidden {
    UIView *material = (UIView *)self;
    if (!LGIsInternalStockMaterialVisibilityMutation(material)) {
        LGLiveBackdropView *glass = objc_getAssociatedObject(material, kGlassKey);
        if (glass) [glass lgStockMaterialVisibilityDidRequest:hidden];
    }
    if (LGMaterialGlassReady(material, kGlassKey)) hidden = YES;
    %orig(hidden);
}

- (void)setFrame:(CGRect)frame   { %orig(frame);  LGResyncGlassGeometry((UIView *)self, kGlassKey); }
- (void)setBounds:(CGRect)bounds { %orig(bounds); LGResyncGlassGeometry((UIView *)self, kGlassKey); }
- (void)setCenter:(CGPoint)center{ %orig(center); LGResyncGlassGeometry((UIView *)self, kGlassKey); }

%end
