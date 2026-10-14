# LiquidAss: same-process local renderer validation

This directory is a **minimal validation carrier**, not a second product or a complete LiquidAss release.

- Main candidate sources remain the LiquidAss `Hooks`, `Shared` and Backboard modules.
- The local interface uses the exact production shader and shared 108/2/1.6/16pt material parameters. System paths and experimental CA pressure routing stay off by default.
- Only the existing `org.liquidass.native-play-lab` self-check is changed. This harness supplies its own explicitly declared **static asset**; it does not capture a system background or another app.
- Build uses **GitHub Actions macOS / Apple Xcode tools only**. No Linux compilation/linking, signing, automatic installation, release upload, preference mutation or restart.
- `NativePlayLab-local-renderer-build16-UNSIGNED.ipa` is an unsigned test artifact, not an install-ready system tweak.
- A CI build succeeding does not establish class runtime, screen presentation, touch XY response, system-background availability or iOS26 visual parity. Those require separate evidence.

The public branch is isolated from `main`. `source-input-manifest.json` fixes each original/additional source hash. No closed reference binary/shader/resources or device Documents are included.
