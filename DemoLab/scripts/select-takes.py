#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Freeze the lowest-loss passed take for every locale and current scenario."""
from pathlib import Path
import argparse
import json
import shutil
from narration import verified_scenes

ROOT=Path(__file__).resolve().parents[1]
LOCALES=['en','ko','ja','zh-Hans','zh-Hant']
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--batches',nargs='+',type=Path,required=True)
p.add_argument('--locales',nargs='+',choices=LOCALES,default=LOCALES)
a=p.parse_args()
if a.output.exists():p.error('selection output already exists')
assets=json.loads((ROOT/'publication.json').read_text())['assets']
selected={}
for locale in a.locales:
    selected[locale]={}
    for asset in assets:
        name=asset['scene'];candidates=[]
        for folder in a.batches:
            files=list(folder.glob(name+'-[0-9].take.json')) if asset.get('presentation')=='dual' else list(folder.glob(name+'.take.json'))
            if len(files)!=(2 if asset.get('presentation')=='dual' else 1):continue
            rows=[json.loads(file.read_text()) for file in files]
            if all(r.get('locale')==locale and r['status']=='passed' and r['frames']>0 and r['droppedFrames']/r['frames']<=.01 and r['durationSeconds']<=asset['maxSeconds'] for r in rows):
                try:
                    for file, record in zip(files, rows):
                        movie=file.with_name(file.name.removesuffix('.take.json')+'.mov')
                        verified_scenes(movie, dict(asset, locale=locale), record)
                    if asset.get('presentation')=='dynamic-dual':
                        secondary=folder/(name+'.secondary.json')
                        metadata=json.loads(secondary.read_text())
                        if metadata['frames']<=0 or metadata['droppedFrames']/metadata['frames']>.01:continue
                except (ValueError, OSError):continue
                candidates.append((max(r['droppedFrames']/r['frames'] for r in rows),str(folder),files))
        if not candidates:raise SystemExit(f'No current accepted take: {locale}/{name}')
        _,folder,files=min(candidates,key=lambda c:(c[0],c[1]))
        for file in files:
            base=file.name.removesuffix('.take.json')
            for extension in ['mov','ass','timeline.json','take.json','scene.json']:
                if not (Path(folder)/(base+'.'+extension)).is_file():raise SystemExit(f'Missing original/sidecar: {file}')
        selected[locale][name]={'batch':folder,'files':[f.name.removesuffix('.take.json') for f in files]}
a.output.mkdir(parents=True)
for locale,scenes in selected.items():
    destination=a.output/locale;destination.mkdir()
    for selection in scenes.values():
        for base in selection['files']:
            extras = ['secondary.mov','secondary.json'] if next((a for a in assets if a['scene']==base), {}).get('presentation')=='dynamic-dual' else []
            for extension in ['mov','ass','timeline.json','take.json','scene.json'] + extras:
                name=base+'.'+extension;shutil.copy2(Path(selection['batch'])/name,destination/name)
(a.output/'selection.json').write_text(json.dumps(selected,ensure_ascii=False,indent=2)+'\n')
print('Selected',sum(map(len,selected.values())),'current passed films')
