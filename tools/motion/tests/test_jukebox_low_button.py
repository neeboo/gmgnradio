import json
import hashlib
import struct
import unittest
from pathlib import Path

from tools.motion.build_jukebox_low_button import CONTACT, PRESS_END, DURATION, source_time, derive_vrma, derive_vmd
from tools.motion.gmgn_motion_factory import build_vmd, build_vrma


class LowButtonTests(unittest.TestCase):
    def test_deliverable_bundle_ids_hashes_and_finite_metadata(self):
        folder = Path(__file__).resolve().parents[3]/'apps/macos/Resources/MMDMotions'
        for avatar, extension in [('vrm', 'vrma'), ('pmx', 'vmd')]:
            motion_id = 'gmgn.motion.device.jukebox-low-button-'+avatar
            manifest = json.loads((folder/(motion_id+'.json')).read_text())
            self.assertEqual(manifest['id'], motion_id)
            self.assertEqual(manifest['entry'], motion_id+'.'+extension)
            self.assertFalse(manifest['loop'])
            self.assertEqual(manifest['sha256'], hashlib.sha256((folder/manifest['entry']).read_bytes()).hexdigest())
            self.assertEqual(manifest['derivation']['phases'], ['reach', 'press-hold', 'retract'])

    def test_reach_hold_retract_is_finite_and_returns_to_original_pose(self):
        self.assertEqual(source_time(0), 0)
        self.assertEqual(source_time(CONTACT), CONTACT)
        self.assertEqual(source_time((CONTACT+PRESS_END)/2), CONTACT)
        self.assertAlmostEqual(source_time(DURATION), 0)

    def test_deterministic_formats_keep_source_and_have_finite_timeline(self):
        fixture = Path(__file__).resolve().parents[1]/'fixtures/right-hand-wave-request.json'
        spec = json.loads(fixture.read_text())['motionSpec']
        vrma = derive_vrma(build_vrma(spec))
        self.assertEqual(vrma, derive_vrma(build_vrma(spec)))
        length = struct.unpack_from('<I', vrma, 12)[0]
        document = json.loads(vrma[20:20+length])
        for sampler in document['animations'][0]['samplers']:
            self.assertEqual(document['accessors'][sampler['input']]['max'], [DURATION])
        vmd = derive_vmd(build_vmd(spec))
        self.assertEqual(vmd, derive_vmd(build_vmd(spec)))
        count = struct.unpack_from('<I', vmd, 50)[0]
        self.assertEqual(max(struct.unpack_from('<I', vmd, 54+i*111+15)[0] for i in range(count)), 102)


if __name__ == '__main__':
    unittest.main()
