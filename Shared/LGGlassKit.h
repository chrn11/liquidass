#pragma once
#import <UIKit/UIKit.h>
#import "LGSurfaceDescriptor.h"

@class LGLiveBackdropView;

#pragma mark - class / ancestry helpers

BOOL hasAncestorOfClassName(UIView *v, NSString *clsName);
BOOL ancestorNameContains(UIView *v, NSString *sub);

BOOL isExactClass(UIView *v, NSString *name);

#pragma mark - per-host enable

BOOL lgHostEnabled(NSString *prefix);
void LGInvalidateGlassPreferenceCache(void);

BOOL LGProcessMatchesExclusionList(id list);

void lgObservePreferenceReload(void (^handler)(void));

#pragma mark - injection registry (live disable -> restore)

extern void *kGlassKey;
void lgTrackGlass(UIView *glass, NSString *prefix, UIView *material);
// Explicit lifecycle boundary; reusing a retained glass requires a fresh bind.
void lgUntrackGlass(UIView *glass);

typedef struct {
    const void *associationKey;
    __unsafe_unretained LGLiveBackdropView *glass;
    __unsafe_unretained UIView *material;
    LGSurfaceDescriptorV1 surface;
} LGMaterialSurfaceDescriptor;
BOOL LGDescribeMaterialSurface(UIView *material, const void *associationKey,
                               LGMaterialSurfaceDescriptor *outDescriptor);

void lgSuppressStock(UIView *v, NSString *prefix, BOOL setHidden);

#pragma mark - registered material lifecycle

LGLiveBackdropView *LGCreateRegisteredGlass(CGRect frame,
                                             NSString *groupName,
                                             NSString *prefix);

LGLiveBackdropView *LGInstallRegisteredGlassInMaterial(UIView *material,
                                                        const void *associationKey,
                                                        NSString *prefix,
                                                        UIEdgeInsets outset,
                                                        CGFloat cornerRadius,
                                                        NSString *groupName);
// True only when this host's CA filter readback is valid; not final presentation.
BOOL LGMaterialGlassReady(UIView *material, const void *associationKey);

#pragma mark - material host router

typedef BOOL (^LGMaterialHostMatcher)(UIView *material);
typedef CGFloat (^LGMaterialHostCornerRadiusProvider)(UIView *material);
typedef void (^LGMaterialHostPostInstall)(UIView *material,
                                          LGLiveBackdropView *glass);
void LGRegisterMaterialHost(NSString *prefix,
                            NSInteger priority,
                            LGMaterialHostMatcher matcher,
                            UIEdgeInsets outset,
                            LGMaterialHostCornerRadiusProvider cornerRadiusProvider,
                            NSString *groupName,
                            LGMaterialHostPostInstall postInstall);
