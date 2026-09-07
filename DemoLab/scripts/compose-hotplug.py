#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Show the real second-screen recording only while that capture is connected."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('directory', type=Path)
p.add_argument('scene')
args = p.parse_args()
main = args.directory / (args.scene + '.mov')
secondary = args.directory / (args.scene + '.secondary.mov')
metadata = json.loads(secondary.with_suffix('.json').read_text())
record_path = main.with_suffix('.take.json')
record = json.loads(record_path.read_text())
start, end = metadata['start'], metadata['end']
duration = float(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','default=nw=1:nk=1',main]))
if not 0 <= start < end <= duration + .1:
    raise SystemExit('secondary capture is outside the primary clock')
if metadata['frames'] <= 0 or metadata['droppedFrames'] / metadata['frames'] > .01:
    raise SystemExit('secondary capture failed quality checks')
output = main.with_suffix('.mkv')
if output.exists():
    raise SystemExit('composite already exists')
filters = (
    f'[0:v]setpts=PTS-STARTPTS,fps=30[main];'
    f'[1:v]setpts=PTS-STARTPTS,trim=duration={end-start},setpts=PTS+{start}/TB[secondary];'
    f'color=c=0x1D1D1F:s=1920x1200:r=30:d={duration}[absent];'
    f'[absent][secondary]overlay=eof_action=pass:repeatlast=0:enable=\'between(t,{start},{end})\'[right];'
    '[main][right]hstack=inputs=2:shortest=1[out]'
)
subprocess.run(['ffmpeg','-v','error','-i',main,'-i',secondary,'-filter_complex',filters,
                '-map','[out]','-c:v','ffv1','-threads','4','-level','3',output],check=True)
def sha(file):
    with file.open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()
main.with_suffix('.primary.take.json').write_text(json.dumps(record,indent=2)+'\n')
record['compositeSources'] = [dict(file=main.name,sha256=sha(main),capture=record['capture']),
                              dict(file=secondary.name,sha256=sha(secondary),capture=metadata)]
record['frames'] += metadata['frames']
record['droppedFrames'] += metadata['droppedFrames']
record_path.write_text(json.dumps(record,indent=2)+'\n')
print(output)
