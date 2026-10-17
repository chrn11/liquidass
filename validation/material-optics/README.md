# Narrow optical-material candidate review

This is an isolated **same-input macOS Metal comparison**, not a new App or a product release. Original `Shared`, `Hooks`, provider, state, source lifetime, normal renderer and production version remain unchanged while this model is reviewed.

- `baseline.metal`: exact frozen shader used for the actual original-App build28 touch tests.
- `candidate.metal`: regenerated from the new original `LGButtonOpticsFormula.inc`; it replaces only transmission/secondary-path and radial-limiter mathematics. It is not a closed-source shader or external reflection model.
- The reviewer uses exactly the same live-source contract layout, original240B uniforms and108/2/1.6/16pt parameters for both variants.
- Source bytes are the same original own botanical/grid228×228 with target132×132 at(48,48). Black/gray/white controls are input textures, not CPU-generated material pixels.
- All images come from actual completed Metal command buffers. PNG export only reorders BGRA→RGBA; it adds no blur, light, recoloring, sharpen or compositing.
- Release, uniform-source passivity, zero-thickness and shape-outside source preservation are separate guards. Their success is not a visual-parity result.

No Linux compiler, signing, device install, system hook, permission or restart is performed. The old product class's runtime shader pin is intentionally **not updated** until parent review accepts the new material. It would reject a mismatched new header; this candidate is not claimed as product-integrated simply because its formula can compile.
