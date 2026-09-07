# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import narration
from video_theme import restyle


class NarrationRevisionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.movie = self.root/'demo.mov'
        self.current = self.root/'current.json'
        self.scene = dict(name='demo', title='Title', steps=[
            dict(kind='caption', text='Old words'),
            dict(kind='key', chord='cmd - n'),
            dict(kind='beat', ms=1200),
            dict(kind='typeText', app='Docs', text='Actual input'),
        ])
        source = json.dumps(self.scene).encode()
        self.movie.with_suffix('.scene.json').write_bytes(source)
        self.record = dict(sceneSHA256=hashlib.sha256(source).hexdigest())
        self.timeline = dict(events=[dict(track='caption',text='Old words',start=.2,end=3),
                                     dict(track='keys',text='cmd - n',start=.8,end=2)])
        self.movie.with_suffix('.timeline.json').write_text(json.dumps(self.timeline))

    def revise(self, scene):
        self.current.write_text(json.dumps(scene))
        with patch.object(narration, 'current_scene', return_value=self.current):
            return narration.revised_timeline(self.movie, {}, self.record)

    def test_copy_edits_keep_the_recorded_clock_and_inputs(self):
        revised = copy.deepcopy(self.scene)
        revised['steps'][0]['text'] = 'New words'
        result = self.revise(revised)
        self.assertEqual(result['events'][0],dict(track='caption',text='New words',start=.2,end=3))
        self.assertEqual(result['events'][1], self.timeline['events'][1])

    def test_action_timing_and_typed_text_changes_require_recapture(self):
        for index, field, value in [(1,'chord','cmd - w'),(2,'ms',1500),(3,'text','Different input')]:
            revised = copy.deepcopy(self.scene)
            revised['steps'][index][field] = value
            with self.assertRaisesRegex(ValueError, 'actions or timing'):
                self.revise(revised)

    def test_tampered_capture_scene_is_rejected(self):
        self.movie.with_suffix('.scene.json').write_text('{}')
        with self.assertRaisesRegex(ValueError,'frozen capture'):
            self.revise(self.scene)

    def test_visual_rejection_cannot_be_reselected_as_an_accepted_capture(self):
        self.movie.with_suffix('.rejected.json').write_text('{"reason":"notification visible"}')
        with self.assertRaisesRegex(ValueError, 'rejected during visual review'):
            self.revise(self.scene)

    def test_ass_keeps_keycast_but_replaces_narration(self):
        key='Dialogue: 1,0:00:00.80,0:00:02.00,Keys,,0,0,0,,⌘N'
        original='Dialogue: 0,0:00:00.20,0:00:03.00,Caption,,0,0,0,,Old words\n'+key
        timeline=copy.deepcopy(self.timeline)
        timeline['events'][0]['text']='새 창이 열려요.'
        output=narration.revise_ass(original,timeline)
        self.assertIn(key,output)
        self.assertNotIn('Old words',output)
        self.assertIn('새 창이 열려요.',output)

    def test_overlay_styles_live_inside_the_desktop(self):
        styles='\n'.join('Style: '+','.join([name,'Helvetica Neue','36','&HFFFFFF','&HFFFFFF','&HFF000000','&HFF000000','0','0','0','0','100','100','0','0','1','0','0','1','128','530','24','1']) for name in ['Caption','Chapter','Keys'])
        rows=[line[7:].split(',') for line in restyle(styles,'ko').splitlines()]
        self.assertEqual(rows[0][18:22],['2','110','110','96'])
        self.assertEqual(rows[1][18:22],['7','32','700','54'])
        self.assertEqual(rows[2][18:22],['9','1300','32','54'])
        self.assertTrue(all(row[15]=='3' for row in rows))
