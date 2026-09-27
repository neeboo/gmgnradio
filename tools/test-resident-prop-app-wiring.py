"""Hostless wiring guard; behavioral validation lives in the Swift tool tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'apps/macos/Sources/GMGNRadio'


class PropAppWiring(unittest.TestCase):
    def test_dynamic_decoration_discovery(self):
        source = (APP / 'App/GMGNRadioApp.swift').read_text()
        self.assertIn('state.generatedProp == nil ? nil : id', source, 'generated decoration discovery missing')
        self.assertIn('Set(manifest.activities.flatMap(\\.propIDs)).union(generatedPropIDs)', source)
        self.assertNotIn('union(context.state.objectStates.keys)', source, 'internal object state leaked into resident context')

    def test_independent_machine_collision_survives_marble_install(self):
        source = (APP / 'App/GMGNRadioApp.swift').read_text()
        self.assertTrue('ResidentPropPlacementConfiguration.independentCollisionVolumes' in source, 'independent colliders missing')

    def test_tools_and_editor_share_placement_service(self):
        source = (APP / 'App/GMGNRadioApp.swift').read_text()
        for fragment in ['ResidentPropToolBridge(', 'configureResidentPropEditor(',
                         'synchronizeOwnedResidentProps()', 'prepareResidentProp(',
                         'residentPropPlacementService(', 'allowsPropMutation: !input.isBackground']:
            self.assertTrue(fragment in source, fragment)

    def test_new_stable_schema_migrates_once(self):
        source = (APP / 'Agent/AgentConversationService.swift').read_text()
        self.assertTrue('.tools.v7' in source, 'v7 missing')
        self.assertTrue('.tools.v6' not in source, 'old pre-capability schema still resumed')
        self.assertTrue('.tools.v6' not in source, 'old placement-only schema still resumed')

    def test_prop_capability_is_explicitly_bound_and_receipt_driven(self):
        runtime = ROOT / 'apps/macos/Packages/WorldRuntime/Sources/WorldRuntime'
        layout = (runtime / 'PropCapability.swift').read_text()
        self.assertIn("metadata[\"gmgn.prop-capability.v1\"]", str((runtime / 'WorldSimulation.swift').read_text()),
                      'capability binding must persist as object metadata')
        self.assertIn('interactionReach', layout, 'operation spots must stay inside the motion reach')
        self.assertIn('"coffee.brew"', layout)
        simulation = (runtime / 'WorldSimulation.swift').read_text()
        self.assertIn('.enableCapability', simulation)
        self.assertIn('unsupportedCapability', simulation, 'unknown templates must fail clearly')
        bridge = (APP / 'Agent/ResidentPropToolBridge.swift').read_text()
        self.assertIn('enable_prop_capability', bridge)
        context = (APP / 'Agent/WorldAgentContext.swift').read_text()
        self.assertIn('rebuildPropActivities', context)
        self.assertIn('isPropCapabilityActivity', context)
        app = (APP / 'App/GMGNRadioApp.swift').read_text()
        self.assertIn('isNaturalIdleFallback', app,
                      'fallback playback must fail the usage instead of counting as success')

    def test_limited_hold_uses_same_service_and_current_avatar(self):
        source = (APP / 'App/GMGNRadioApp.swift').read_text()
        self.assertIn('avatarRuntime.snapshot.avatar', source)
        self.assertIn('heldProp', source)
        self.assertIn('synchronizeResidentPropPresentation()', source)
        bridge = (APP / 'Agent/ResidentPropToolBridge.swift').read_text()
        for name in ['hold_prop', 'adjust_held_prop_grip', 'return_held_prop']:
            self.assertIn(name, bridge)

    def test_editor_rejects_input_before_enqueue_and_uses_session_lease(self):
        source = (APP / 'App/GMGNRadioApp.swift').read_text()
        method = source.split('private func sendResidentSubmission(', 1)[1].split('\n    private func ', 1)[0]
        self.assertLess(method.index('ResidentPropHostError.editorOpen'), method.index('ensureResidentLoop()'))
        self.assertGreaterEqual(source.count('self.isResidentPropEditorCurrent(context: context, editorID: editorID)'), 2)
        editing = source.split('private func setResidentPropEditing(', 1)[1].split('\n    private func ', 1)[0]
        self.assertNotIn('residentAgentLoop?.stop()', editing)
        self.assertTrue('residentPropEditingPreferenceEnabled' in editing)
        self.assertTrue('receiveEvent(' in editing)


if __name__ == '__main__':
    unittest.main()
