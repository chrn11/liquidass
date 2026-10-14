#!/usr/bin/env python3
"""Check common formula source routing; this does NOT compile MSL or prove GPU parity."""
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parents[1]
formula = root / "Shared/LGButtonOpticsFormula.inc"
material = (root / "Shared/LGButtonMaterialCandidate.h").read_text()
msl_header = (root / "Shared/LGButtonOpticsShaderSource.h").read_text()
backboard = (root / "LiquidAssBackboardd/Tweak.mm").read_text()
cpu_test = (root / "scripts/test_button_material_candidate.c").read_text()
hooks = (root / "Hooks/Controls.x").read_text()
registry = (root / "Shared/LGHostRegistry.h").read_text()
live = (root / "Shared/LGLiveBackdropView.m").read_text()
formula_text = formula.read_text()
assert '#include "LGButtonOpticsFormula.inc"' in material
assert '#include "LGButtonOpticsFormula.inc"' in msl_header
assert '"../Shared/LGButtonOpticsShaderSource.h"' in backboard
assert 'kLGButtonOpticsFormulaMSL' in backboard
assert 'stringByReplacingOccurrencesOfString:marker' in backboard
assert '//__LG_BUTTON_OPTICS_FORMULA__' in backboard
# The marker must be inside the runtime shader raw string, not merely in the
# Objective-C replacement argument. The previous guard missed that failure.
shader = backboard.split('kShaderSrc = R"MSL(', 1)[1].split(')MSL";', 1)[0]
marker = '//__LG_BUTTON_OPTICS_FORMULA__'
assert shader.count(marker) == 1
assert '#if LG_BUTTON_OPTICS_COMPILED\n' + marker + '\n#endif' in shader
assert shader.index(marker) < shader.index('LGButtonOpticsEvaluate(')
assert '#define LG_BUTTON_OPTICS_COMPILED 0' in backboard
assert 'g_buttonOpticsCompiled.load(std::memory_order_acquire)' in backboard
assert 'compatibilitySource options:nil error:&err' in backboard
assert 'LGButtonOpticsEvaluate(' in backboard
assert 'LGButtonOpticsEvaluate(' in cpu_test
candidate_branch = backboard.split('if (buttonCandidate) {', 1)[1].split('\n    if (u.useGlyphMask < 0.5', 1)[0]
for forbidden in ('tintColor', 'dispersion', 'backdropSampleUV', 'zoomMix', 'quartzGlassHighlight'):
    assert forbidden not in candidate_branch, forbidden
assert 'sampleU' in formula_text and 'sampleV' in formula_text
assert 'buttonCandidateDisplacement' not in backboard
assert 'PrefsButton.MaterialCandidate.Enabled' in hooks
assert 'NSNumber.class' in hooks and 'preferenceIsTrue' in hooks
assert 'LGHostIdentifierPrefsButtonCandidate) return 0.0' in live
assert 'host == &kLGHostRegistry[LGHostIdentifierPrefsButtonCandidate]' in live
assert 'removeFromSuperlayer' in live
assert '"PrefsButtonCandidate"' in backboard
assert '"#00000000", "#00000000"' in registry
print("shared formula SHA256:", hashlib.sha256(formula_text.encode()).hexdigest())
print("CPU/MSL common-source routing and candidate isolation: PASS")
