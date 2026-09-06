#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Align real per-display recordings to their common first-frame clock."""
from pathlib import Path
import argparse,json,hashlib,subprocess,shutil
p=argparse.ArgumentParser(description=__doc__);p.add_argument('directory',type=Path);p.add_argument('scene');args=p.parse_args()
files=sorted(args.directory.glob(args.scene+'-[0-9].mov'))
if len(files)!=2:raise SystemExit('expected exactly two display recordings')
records=[json.loads(f.with_suffix('.take.json').read_text()) for f in files]
items=sorted(zip(files,records),key=lambda x:(x[1]['capture']['x'],x[1]['capture']['y']))
files,records=map(list,zip(*items))
if any(r['status']!='passed' or r['frames']<=0 or r['droppedFrames']/r['frames']>.01 for r in records):raise SystemExit('a display failed capture acceptance')
if len({r['sceneSHA256'] for r in records})!=1:raise SystemExit('different scenes in one composite')
duration=min(r['durationSeconds'] for r in records)
output=args.directory/(args.scene+'.mkv')
if output.exists():raise SystemExit('composite already exists')
command=['ffmpeg','-v','error']
for f in files:command+=['-i',str(f)]
filters=[]
for i,r in enumerate(records):
 offset=r['capture']['captureOffsetSeconds']
 filters.append(f'[{i}:v]setpts=PTS-STARTPTS,tpad=start_duration={offset}:start_mode=clone,trim=duration={duration},fps=60[v{i}]')
filters.append('[v0][v1]hstack=inputs=2[out]')
command+=['-filter_complex',';'.join(filters),'-map','[out]','-c:v','ffv1','-level','3',str(output)]
subprocess.run(command,check=True)
for suffix in ['.ass','.timeline.json','.scene.json']:shutil.copy2(files[0].with_suffix(suffix),output.with_suffix(suffix))
record=dict(records[0],frames=min(r['frames'] for r in records),droppedFrames=max(r['droppedFrames'] for r in records))
record['compositeSources']=[dict(file=f.name,sha256=hashlib.sha256(f.read_bytes()).hexdigest(),capture=r['capture']) for f,r in zip(files,records)]
output.with_suffix('.take.json').write_text(json.dumps(record,indent=2)+'\n')
print(output)
