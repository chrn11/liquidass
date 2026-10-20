# App-owned background source provider (candidate)

## Scope and opt-in

This adds only `LGAppOwnedButtonSourceProvider`, implementing the existing `LGLocalButtonSourceProvider` protocol. It never changes `LGLocalButtonMaterialView`, the 240-byte uniforms, or either shader. The baseline's `LG_LOCAL_BUTTON_RENDERER_COMPILED` remains `0`; a build must explicitly set it to `1` and the host must pass `explicitOptIn:YES` to both provider and material view. Approximate/static sources remain disabled (`allowApproximateSource:NO`). If anything is unavailable or unsupported, the provider returns `nil` with `lastStatus`; the host keeps the existing native/CA fallback.

`LiveAppOwnedTexture` means this exact synchronous capture of a host-declared, app-owned `sourceRoot` subtree. It does **not** mean a system backdrop, another process, a window image, or zero-copy/Core Animation live rendering. `renderInContext:` is CPU layer-tree rasterization into a bounded bitmap.

## Minimal host call (main thread)

The host must retain `sourceRoot`, `target`, provider, and material for their intended lifetimes. `sourceRoot` is a deliberately selected, separate opaque background `UIView` subtree; target and material are siblings, not contained in it. The seed device can be the default device; binding pins the exact renderer device before the first capture.

```objc
id<MTLDevice> seedDevice=MTLCreateSystemDefaultDevice();
LGAppOwnedButtonSourceProvider *provider=[[LGAppOwnedButtonSourceProvider alloc]
    initWithSourceRoot:ownedBackgroundRoot targetView:button device:seedDevice
    edgePadding:UIEdgeInsetsMake(16,16,16,16) explicitOptIn:YES];
LGLocalButtonMaterialView *material=[[LGLocalButtonMaterialView alloc]
    initWithFrame:button.frame targetView:button sourceProvider:provider
    allowApproximateSource:NO explicitOptIn:YES];
[button.superview insertSubview:material belowSubview:button];
if (!provider || !material ||
    ![provider bindMaterialViewForFeedbackExclusion:material device:material.device]) {
    // Keep the original native fallback; do not claim the local effect is active.
}
[provider updateTargetGeometryGeneration:state.geometryGeneration];
LGLocalButtonRendererResult r=[material submitOpticalState:state enabled:hostOptIn];
```

Call `updateTargetGeometryGeneration:` with the exact current optical-state generation before submitting after target layout/geometry changes. A changed target rect without a strictly newer generation is rejected. On a source subtree content/model-layout change, call `markSourceContentDirty` on the main thread; after source-root movement the provider also notices its mapped geometry. After replacing/invalidating the source owner call `advanceOwnerGeneration` and invalidate the material's current source. There are no observers, timers, display links, actions, hit-test changes, or duplicated pressure state. Host drives each pull from its existing callback.

## Safety and pixel domain

- The configured root is weakly held and is never guessed. It must be in the target's same `UIWindow`/scene. Target, source root, and explicitly bound renderer may not be equal, ancestor, or descendant in a feedback-producing combination. The renderer must be an `MTKView` sibling of the target on the same Metal device.
- Only `sourceRoot.layer` and descendants are inspected/rendered; no window/superview/target rendering and no `drawViewHierarchyInRect:`. Source and target paths must be finite, axis-aligned 2D transforms. Requested ROI is the target's exact 44×44pt owner-parent rect expanded independently by 0…16pt per edge. The entire ROI must map inside `sourceRoot.bounds` and all clipping ancestors; missing domain returns `nil`, never edge-stretches or mattes.
- On this explicit subtree only, public view/layer class checks reject MTK/WK/web/video/remote/visual-effect and known Metal/EAGL/player/sample-buffer/3D/animated/filter-like layer cases; the tree is capped at 512 nodes. Arbitrary custom drawing that cannot be reliably rendered remains host responsibility and must not be declared CPU-readable. Bitmap render failure or unsupported tree returns `nil`.
- Capture is at the window screen scale, with exact integer dimensions `sourceRect × pointScale`, capped at 304×304px (76pt at 4×). It uses an sRGB CoreGraphics bitmap and `BGRA8Unorm_sRGB` texture, `ShaderRead`, 2D, sample count 1, on the renderer's actual device. Every bitmap alpha byte must be 255. No transparent/matte/fixed-fill path is accepted. Only then are sampled RGB claims set: sRGB texture sampling linearizes RGB, and opaque alpha makes premultiplication exact; `_sRGB` alone is not used to infer premultiplication.
- Three reusable Metal texture slots maximum, each with at most four frame-object leases. A slot is mutated only with zero frame/GPU leases. Completion/dealloc uses locked slot epoch + owner-generation checks; an old callback cannot decrement a later slot reuse. Owner-token allocation saturates rather than wrapping/reusing identity. Full ring/lease cap returns `nil` (`LeaseContention`) without overwriting anything.
- Captures are active-pull/main-thread synchronous and rate limited to at most 15Hz. A clean cached capture can be leased only while no older than 66ms; dirty/geometry changes invalidate it. Frame generation and timestamp change only on a successful new capture, never for repeated pulls or pressure changes. The renderer's original 100ms freshness validation is unchanged; no fresh capture means fallback/`nil`.

## Mac CI and host tests

`tests/test_appowned_lease_policy.c` covers the portable slot-epoch/lease cap, three-slot exhaustion, bounded geometry, 240-byte source contract fields, and alpha/format gates. `tests/LGAppOwnedButtonSourceProviderTests.mm` is an XCTest source for the existing iOS app test host (build that target with `LG_LOCAL_BUTTON_RENDERER_COMPILED=1`). It creates an explicit opaque sibling source view, pulls a real provider texture, changes the view color + marks dirty, then reads **the captured source texture** with `getBytes` to prove pixels and frame generation changed; it does not synthesize or CPU-draw material output. It also holds all three slots, confirms the fourth capture is contention and held pixels do not change, rejects transparent pixels, and refuses window/target-ancestor roots. The prepared cases also cover explicit geometry-generation changes, missing-padding-domain rejection, and a nested MTKView drawable rejection; WK/video class checks are confined to the declared source subtree.

On GitHub Actions `macos-latest` with Xcode selected, invoke `SOURCE_ROOT=/path/to/patch-applied-candidate tests/run_macos_ci.sh` to compile/run the pure C tests and syntax-check provider/XCTest Objective-C++. The Objective-C++ tests require the existing iOS app XCTest host/simulator or the main agent's authorized original-App test path; they are not claimed as run here. No local clang/Xcode build was performed.
