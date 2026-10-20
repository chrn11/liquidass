from pathlib import Path
root = Path(__file__).resolve().parents[1]
controls = (root / "Hooks/Controls.x").read_text()
backboard = (root / "LiquidAssBackboardd/Tweak.mm").read_text()
registry = (root / "Shared/LGHostRegistry.h").read_text()
prefs = (root / "LiquidAssPrefs/LGPRootListController.m").read_text()

assert '"PrefsButton.MaterialCandidate.Enabled"' in controls
assert 'BOOL preferenceIsNSNumber = [preference isKindOfClass:NSNumber.class];' in controls
assert 'BOOL preferenceIsTrue = preferenceIsNSNumber && [preference boolValue];' in controls
assert 'preferenceIsNSNumber, preferenceIsTrue,' in controls
assert '[preference isKindOfClass:NSNumber.class], [preference boolValue]' not in controls
assert '"com.apple.Preferences"' in controls
assert 'object_getClass(self) == LGSettingsBackButton.class' in controls
assert '"_UIButtonBarButton"' in controls and '"_UIBackButtonMaskView"' in controls
assert 'self.window != nil && self.enabled' in controls
assert 'LG_BUTTON_CANDIDATE_VIEW_SIZE_POINTS' in controls
assert 'LG_BUTTON_CANDIDATE_CORNER_RADIUS_RATIO' in controls
method = controls.split('- (void)lg_updateMaterialCandidate {', 1)[1].split('- (void)layoutSubviews {', 1)[0]
for token in ('LGCreateRegisteredGlass', 'PrefsButtonCandidate', 'PrefsButton', 'lgUntrackGlass', 'LGButtonCandidateUpdateInstanceState'):
    assert token in method, token
for forbidden in ('hitTest', 'pointInside', 'addTarget:', 'sendActions', 'accessibility', 'self.hidden =', 'self.userInteractionEnabled ='):
    assert forbidden not in method, forbidden
assert "_glass.userInteractionEnabled = NO;" in controls
assert '[self addTarget:self action:@selector(lg_pop)' in controls
assert "_glyph.userInteractionEnabled = NO;" in controls
assert 'LGRefreshVisibleSettingsBackButtons();' in controls
allocationFailure = method.split('if (!next) {', 1)[1].split('next.userInteractionEnabled', 1)[0]
assert 'if (!requested)' in allocationFailure
assert 'self.glass = nil;' in allocationFailure
assert 'lgUntrackGlass(previous);' in allocationFailure
assert 'LGButtonCandidateUpdateInstanceState(&_candidateMaterialState, false);' in allocationFailure
refresh = controls.split('static void LGRefreshVisibleSettingsBackButtons(void) {', 1)[1].split('%ctor', 1)[0]
assert 'isEqualToString:@"com.apple.Preferences"]' in refresh
assert 'X(PrefsButtonCandidate,' in registry
assert '0.0f, 0.0f, 0.00f, "#00000000", "#00000000"' in registry
assert 'LGReadPreference(@"PrefsButton.MaterialCandidate.Enabled", @NO)' in prefs
assert 'return [value isKindOfClass:NSNumber.class] && [value boolValue];' in prefs
assert '[LGReadPreference(@"PrefsButton.MaterialCandidate.Enabled", @NO) boolValue]' not in prefs
assert prefs.count('LGReadButtonMaterialCandidateEnabled()') == 3
assert 'LGWritePreferenceAndMaybeRequireRespring(' in prefs
assert 'PrefsButton.MaterialCandidate.Enabled' in prefs
assert 'const bool buttonCandidateRequested' in backboard
assert 'LGButtonCandidateBuildGeometry(' in backboard
assert 'LGButtonCandidateFormatsCompatible(' in backboard
assert 'LGButtonCandidateMaxDisplacement(' in backboard
assert 'candidateGeometry.centerX' in backboard and 'candidateGeometry.centerY' in backboard
assert 'candidateGeometry.cornerRadius' in backboard
assert 'candidateGeometry.pointScaleX' in backboard
assert 'origTex.usage == MTLTextureUsageUnknown' in backboard
assert 'origTex.usage & MTLTextureUsageShaderRead' in backboard
assert 'destTex.width, (float)destTex.height' in backboard
assert 'id<MTLTexture> glassSourceTexture = origTex;' in backboard
assert '[enc setFragmentTexture:glassSourceTexture atIndex:0];' in backboard
assert '[enc setFragmentBytes:&lu length:sizeof(lu) atIndex:0];' in backboard
assert 'LGButtonOpticsEvaluate(' in backboard
assert 'optics.sampleU, optics.sampleV' in backboard
assert 'src.sample(s, environmentUV)' in backboard
assert 'return float4(mixedPremul, opticalSample.a);' in backboard
assert backboard.count('LGBOEnvironmentMixPremultipliedChannel(') == 3
assert 'buttonCandidateClampUV' not in backboard
assert 'buttonCandidateDisplacement' not in backboard
assert 'buttonCandidate ? 0.0' not in backboard
assert 'u.tintColor = simd_make_float4(0.0f, 0.0f, 0.0f, 0.0f);' in backboard
assert 'legacy shader retained' in backboard
assert 'buttonCandidateMaxOffset' in backboard
print('button candidate source routing: PASS')
