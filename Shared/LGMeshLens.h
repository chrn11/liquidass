#pragma once
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

// Rounded-rect mesh lens. The layer silhouette stays put; only the sample
// position along the rim moves outward. Clock, keyboard, and tab-bar lenses
// stay on the glyph / mask filter.
BOOL LGMeshLensShouldApply(NSString *filterType, CGRect bounds);
NSString *LGMeshLensSignature(CGRect bounds, CGFloat cornerRadius);
id LGMeshLensTransform(CGRect bounds, CGFloat cornerRadius);
CGFloat LGMeshLensBlurRadius(void);
