# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
import importlib.util
import sys
sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parents[1] / "scripts"))
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('demolab_export', Path(__file__).resolve().parents[1] / 'scripts/export.py')
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)

class ExportAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.movie = Path(self.temp.name) / 'tour.mov'
        self.asset = dict(scene='tour', maxSeconds=48)
        self.record = dict(schemaVersion=2, status='passed', scene='tour', overlay='off',
                           frames=1800, droppedFrames=0,
                           sceneSHA256=exporter.sha(exporter.ROOT / 'scenes/tour.json'))
        self.timeline = dict(durationSeconds=30, events=[dict(track='caption', text='Start', start=0.1)])
        self.info = dict(format=dict(duration='30.1'), streams=[dict(codec_type='video', width=1920, height=1200)])

    def validate(self):
        self.movie.with_suffix('.take.json').write_text(json.dumps(self.record))
        self.movie.with_suffix('.timeline.json').write_text(json.dumps(self.timeline))
        with patch.object(exporter, 'probe', return_value=self.info):
            return exporter.validate_take(self.movie, self.asset)

    def test_accepts_complete_take(self):
        self.assertEqual(self.validate()[1], 30.1)

    def test_rejects_failed_take_even_with_a_playable_movie(self):
        self.record['status'] = 'failed'
        with self.assertRaisesRegex(ValueError, 'passed v2'):
            self.validate()

    def test_rejects_scene_changed_after_capture(self):
        self.record['sceneSHA256'] = 'stale'
        with self.assertRaisesRegex(ValueError, 'scene changed'):
            self.validate()

    def test_rejects_duplicate_live_narration(self):
        self.record['overlay'] = 'keys'
        with self.assertRaisesRegex(ValueError, 'live overlay'):
            self.validate()

    def test_rejects_drops_and_clock_drift(self):
        self.record['droppedFrames'] = 25
        with self.assertRaisesRegex(ValueError, 'capture drops'):
            self.validate()
        self.record['droppedFrames'] = 0
        self.timeline['durationSeconds'] = 26
        with self.assertRaisesRegex(ValueError, 'clock'):
            self.validate()

    def test_rejects_late_opening_and_overlong_take(self):
        self.timeline['events'][0]['start'] = 1.5
        with self.assertRaisesRegex(ValueError, 'opening narration'):
            self.validate()
        self.info['format']['duration'] = '60'
        with self.assertRaisesRegex(ValueError, 'editorial budget'):
            self.validate()

if __name__ == '__main__':
    unittest.main()
