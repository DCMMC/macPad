"""Source-contract regression checks, NOT on-device or visual acceptance.

Run: python3 misc/test_window_resize_stage_contract.py
The actual SpringBoard ABI evidence is documented in
docs/evidence/windowing-programmatic-resize-stage-membership-20260912.md.
"""
import unittest

from test_window_policy_queue_contract import function_body


APPLY = function_body(
    "static void MacWSApplyResizeRequest(NSDictionary *request, NSString *path,\n"
    "                                    NSUInteger attempt) {")
VERIFY = function_body("static void MacWSVerifyResizePostcondition(")


class ResizeStageContract(unittest.TestCase):
    def test_ordinary_geometry_uses_only_current_stage(self):
        selection = APPLY[APPLY.index('NSString *layoutSource = nil;'):
                          APPLY.index('NSInteger *preferredCenterRoleAddress')]
        self.assertIn('if (!requestWindowedRole)', selection)
        self.assertIn('NSSelectorFromString(@"_currentMainAppLayout")', selection)
        self.assertIn('MacWSAppLayoutExactSceneItem(', selection)
        self.assertIn('if (targetLayout && !targetItem)', selection)
        self.assertIn('if (attempt < 20)', selection)
        self.assertIn('MacWSApplyResizeRequest(request, path, attempt + 1)', selection)
        self.assertIn('MacWSFinishResizeRequest(', selection)
        self.assertIn('return;', selection)
        self.assertNotIn('leafAppLayoutForKeyboardFocusedScene', selection)
        self.assertNotIn('recentAppLayouts', selection)

    def test_real_scene_only_metadata_still_exits_before_geometry(self):
        self.assertLess(APPLY.index('if (policyOnly) {'),
                        APPLY.index('UIApplication *application'))
        self.assertLess(APPLY.index('reason=not-current-stage'),
                        APPLY.index('MacWSSetStableModelSize('))

    def test_clone_validates_members_roles_and_sibling_attributes(self):
        check = function_body('static BOOL MacWSResizePreservesAppLayoutSiblings(')
        self.assertIn('originalItems.count != resizedItems.count', check)
        self.assertIn('isEqualToSet:[NSSet setWithArray:resizedItems]', check)
        self.assertEqual(check.count('@"layoutRoleForItem:"'), 2)
        self.assertIn('[originalAttributes isEqual:resizedAttributes]', check)
        self.assertLess(APPLY.index('reason=stage-clone-contract'),
                        APPLY.index('Class requestClass ='))

    def test_ordinary_geometry_never_reorders_or_claims_keyboard_source(self):
        self.assertIn('if (requestWindowedRole && resizedLayout &&', APPLY)
        self.assertIn('if (requestWindowedRole &&\n'
                      '        [transitionRequest respondsToSelector:'
                      'NSSelectorFromString(@"setSource:")])', APPLY)

    def test_non_gesture_transaction_does_not_fake_a_gesture_session(self):
        self.assertIn('transitionRequest, NO);', APPLY)
        self.assertNotIn('transitionRequest, YES);', APPLY)
        self.assertIn('NSSelectorFromString(@"setSceneUpdatesOnly:"),\n'
                      '            NO);', APPLY)

    def test_current_stage_is_the_only_ordinary_postcondition_candidate(self):
        ordinary = VERIFY[VERIFY.index('if (!expectedWindowedRole) {'):
                          VERIFY.index('} else {')]
        self.assertIn('MacWSAppLayoutExactSceneItem(currentLayout', ordinary)
        self.assertIn('[candidateLayouts addObject:currentLayout]', ordinary)
        self.assertNotIn('recentAppLayouts', ordinary)
        self.assertNotIn('leafAppLayoutForKeyboardFocusedScene', ordinary)

    def test_membership_changes_fail_without_restoring_closed_windows(self):
        self.assertIn('roleLanded && sizeLanded && stageMembersPreserved', VERIFY)
        self.assertIn('!landed && stageMembersPreserved && transactionAttempt < 2', VERIFY)
        self.assertIn('visual-acceptance=UNVERIFIED', VERIFY)

    def test_whole_stage_calculation_drops_programmatic_item_ownership(self):
        group = function_body(
            '- (id)_appLayoutByPerformingAutoLayoutIfNeededInAppLayout:')
        original = group.index('laidOutAppLayout = %orig(')
        for cleared in ('MacWSActiveDenseGridPolicy = nil;',
                        'MacWSDenseGridScopeDepth = 0;',
                        'MacWSItemLayoutScopeDepth = 0;',
                        'MacWSInitialLayoutScopeDepth = 0;',
                        'MacWSActiveLayoutSceneIdentifier = nil;'):
            self.assertLess(group.index(cleared), original)
        self.assertIn('MacWSActiveDenseGridPolicy = previousPolicy;', group)
        self.assertIn('MacWSDenseGridScopeDepth = previousDenseDepth;', group)
        self.assertGreater(group.index('MacWSAppLayoutByAvoidingFloatingDock('),
                           group.index('MacWSActiveDenseGridPolicy = previousPolicy;'))

    def test_nested_item_calculator_rebinds_each_sibling_exact_identity(self):
        item = function_body('- (CGRect)_frameForLayoutRole:')
        self.assertIn('MacWSAppLayoutItemForRole(appLayout, layoutRole)', item)
        self.assertIn('MacWSStableModelSize(scene, &modelSize)', item)
        self.assertIn('MacWSActiveDenseGridPolicy = itemPolicy;', item)
        self.assertIn('MacWSActiveLayoutSceneIdentifier = host ? scene : nil;', item)
        self.assertIn('MacWSDenseGridScopeDepth = host ? 1 : 0;', item)


if __name__ == '__main__':
    unittest.main()
