# Bounded image-driven edge-radiance candidate

**Scope/status:** independent source-only candidate derived from the finite-cap single-path baseline. This is an image-driven, low-frequency edge cue; it is **not** a physical reflection/environment map and is not visually or at runtime accepted yet.

## Source and boundary

The integrator reads only the same `src` texture already passed to the opt-in local-button optics candidate and requires `buttonSourceOverscanEnabled`. The four taps are mapped through the existing local-source transform and clamped to the source ROI extended by at most `16 * pointScale` pixels on every side (16 points). No new source, asset, environment texture, white tint, fixed lamp, second sharp image, or source-contract change is introduced. The shared formula's existing public/default/Backboard outputs keep `environmentWeight == 0`; only the generated local candidate call assigns the edge weight. The 240-byte uniform ABI, 1/4-tap primary minification footprint, main ray, cap/contact/AA profile, source lease, and legacy paths are not changed.

## Defined approximation

Let the already-computed primary transmitted sample coordinate be `c`; the four image-plane samples are `c ± r n` and `c ± r t`, where `n` is the local projected surface-normal direction, `t=(-n.y,n.x)`, and

`r = smoothCapped( max(h,0) * tan(12°), 16 * pointScale )`.

`h` is the existing local finite-cap/contact height in target texels. `12°` is an explicit **image-space cone-width heuristic**, not a recovered physical incidence angle or roughness measurement. Since the leased 2-D capture contains no scene depth, light position, or external environment radiance, a true angular-to-world-source footprint cannot be inferred; the formula deliberately makes no such claim. Each sample is an actual texel from the leased background, and the support is additionally clipped to the legal 16-point overscan rectangle.

The low-frequency radiance estimate is `E=(S0+S1+S2+S3)/4`. The candidate weight is `w = min(0.28, edgeBand * FSchlick)`, with `edgeBand=1-smoothstep(depth/L)`, `L=min(max(bezel,1), max(1.5*pointScale, 0.15*min(width,height)))`, and Schlick `F0=((ior-1)/(ior+1))²`, `F=F0+(1-F0)(1-cosθ)^5`, `cosθ=sqrt(max(0,1-nx²-ny²))`. This is a bounded reflectance-shaped *mix coefficient*, not proof of a reflected ray. The result is a premultiplied-alpha-preserving convex mix `C=(1-w)T+wE`, `0≤w≤0.28`; the equal nonnegative quadrature weights sum to one. Thus constant black/gray/white are identities, and every output channel stays between the primary source channel and the range of the four captured taps. Touch-dependent `h`/normal/weight/radius are continuous; zero pressure leaves the prior primary result unchanged.

## Tap budget

The new integral is exactly **four extra source taps**, branch-gated by both candidate weight and explicit overscan lease. The primary source AA code remains intact (1 or 4 taps). Existing transparent-sample fallback can add one more source read, so the candidate branch's conservative source-read maximum is **4 primary + 1 fallback + 4 edge = 9**; do not report “8 full-fragment taps.” This count excludes non-source work and does not characterize unrelated old rendering paths.

## Validation state

The Mac-only C regression `validation/edge-radiance-candidate/test_edge_radiance_cpu.c` covers constant-source identity, quadrature, channel energy bounds, shape exterior, zero/off/lease gates, edge bounds, and touch continuity. Run it via `scripts/test_button_edge_radiance_macos.sh` on macOS only. `scripts/test_button_edge_radiance_source.py` is mechanical source/hash checking. The generator's candidate MSL byte hash is embedded in `Shared/LGLocalButtonShaderSource.h`.

**Not run here:** C/ObjC++/Metal compilation, SDK/linking, GPU/runtime, and visual comparison. The candidate remains unproven until the parent runs the Mac-only checks and same-source GPU/visual comparison; the existing product and system paths remain unchanged.
