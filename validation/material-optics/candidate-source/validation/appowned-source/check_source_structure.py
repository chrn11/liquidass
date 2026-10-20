#!/usr/bin/env python3
import hashlib, json, pathlib, re, sys

WORK=pathlib.Path(__file__).resolve().parents[1]
CANDIDATE=pathlib.Path('/var/minis/shared/liquidass-appowned-source-candidate-cada8c48-7dd9-4ba0-9e09-a48c9796f811')
BASELINE_MANIFEST=pathlib.Path('/var/minis/workspace/liquidass-button-overscan-main/main-final-manifest.json')
manifest=json.loads(BASELINE_MANIFEST.read_text())
checks=[]
def check(ok, label):
    checks.append((bool(ok),label))
    if not ok: print('FAIL:',label)

base=manifest['finalSourceSHA256']
check(len(base)==135,'exactly 135 baseline manifest files')
for rel,want in base.items():
    p=CANDIDATE/rel
    check(p.is_file() and hashlib.sha256(p.read_bytes()).hexdigest()==want,
          'baseline hash '+rel)

provider=(CANDIDATE/'Shared/LGAppOwnedButtonSourceProvider.mm').read_text()
header=(CANDIDATE/'Shared/LGAppOwnedButtonSourceProvider.h').read_text()
policy=(CANDIDATE/'Shared/LGAppOwnedLeasePolicy.h').read_text()
contract=(CANDIDATE/'Shared/LGLocalButtonSourceContract.h').read_text()
material=(CANDIDATE/'Shared/LGLocalButtonMaterialView.mm').read_bytes()
shader=(CANDIDATE/'Shared/LGLocalButtonShaderSource.h').read_bytes()
check('LG_LOCAL_BUTTON_RENDERER_COMPILED 0' in contract,'default compile gate remains zero')
check('currentBackgroundFrameForTargetView:' in provider,'existing provider protocol implemented')
check('initWithSourceRoot:' in header and 'explicitOptIn:(BOOL)explicitOptIn' in header,
      'strict explicit-owned-root opt-in API')
check('bindMaterialViewForFeedbackExclusion:' in header,'explicit renderer feedback binding')
check('updateTargetGeometryGeneration:' in header,'explicit target geometry generation API')
check('renderInContext:context' in provider and provider.count('renderInContext:')==1,
      'only one explicit source-root layer render')
check('drawViewHierarchyInRect' not in provider and 'window.layer renderInContext' not in provider,
      'no window or view-hierarchy capture')
check(not any(x in provider for x in ('CADisplayLink','NSTimer','NSNotificationCenter')),
      'no provider timer/displaylink/global observer')
check('LG_APP_OWNED_TEXTURE_SLOT_COUNT 3u' in policy and
      'LG_APP_OWNED_MAX_LEASES_PER_SLOT 4u' in policy,
      'three bounded texture slots and four frame leases per slot')
check('LGAppOwnedLeaseSlotValue leasePolicy' in provider and
      'slot.policy' not in provider and 'cacheSlot.policy' not in provider and
      '&slot->leasePolicy' in provider,
      'lease helper receives addressable private slot ivar')
check('compare_exchange_weak' in provider and 'fetch_add' not in provider,
      'owner token allocation saturates without wrapping')
check('@catch (NSException *exception)' in provider and
      'renderSucceeded=NO' in provider,
      'layer render exception returns unsupported instead of success')
check('frameTimestampMonotonic=now' in provider and 'contract.frameGeneration=++_frameGeneration' in provider,
      'new captures mint real monotonic time and frame generation')
check('1.0/15.0' in provider and 'kLGAppOwnedMaximumCacheAge = 0.066' in provider and
      '304u' in provider,'15Hz capture, <=66ms cache, and 304px bound')
check('bitmap[i]!=255u' in provider and 'TransparentCaptureRejected' in provider,
      'opaque-only alpha verification')
check('MTLPixelFormatBGRA8Unorm_sRGB' in provider and '!=81u' in provider,
      'actual BGRA8Unorm_sRGB format is checked')
check('LGLocalSourceLiveAppOwnedTexture' in provider and
      'LGLocalSourceStaticAsset' not in provider and 'LGLocalSourceDeclaredSyntheticColor' not in provider,
      'LIVE kind only for actual explicit subtree capture')
check('target.superview' in provider and 'LGAppOwnedContainsView' in provider,
      'target/material/root feedback relationships checked')
check(hashlib.sha256(material).hexdigest()==base['Shared/LGLocalButtonMaterialView.mm'],
      'material renderer source remains byte-identical')
check(hashlib.sha256(shader).hexdigest()==base['Shared/LGLocalButtonShaderSource.h'],
      'original shader source remains byte-identical')
check((WORK/'tests/test_appowned_lease_policy.c').is_file(),'pure C tests prepared')
check((WORK/'tests/LGAppOwnedButtonSourceProviderTests.mm').is_file(),'ObjC++ host tests prepared')
check((WORK/'tests/run_macos_ci.sh').is_file(),'Mac/Xcode CI runner prepared')
print(f'{sum(ok for ok,_ in checks)}/{len(checks)} mechanical source checks passed')
sys.exit(0 if all(ok for ok,_ in checks) else 1)
