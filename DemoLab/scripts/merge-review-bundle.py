#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Replace explicitly selected films in a reviewed bundle, preserving prior evidence."""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import shutil

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('bundle',type=Path);p.add_argument('patch',type=Path);p.add_argument('--archive',type=Path,required=True)
a=p.parse_args()
base=json.loads((a.bundle/'manifest.json').read_text());patch=json.loads((a.patch/'manifest.json').read_text())
if base['locale']!=patch['locale']:p.error('locale mismatch')
by_scene={x['scene']:x for x in base['assets']}
new_audit=a.patch/'evidence/ocr-audit.json'
if not new_audit.is_file():p.error('patch needs a completed OCR audit')
new=json.loads(new_audit.read_text())
if new['status']!='passed' or {Path(m['movie']).stem for m in new['movies']}!={x['scene'] for x in patch['assets']}:p.error('patch OCR evidence does not cover the patch')
for asset in patch['assets']:
    if asset['video'] != asset['scene']+'.mp4' or asset['poster'] != asset['scene']+'.jpg':p.error('unexpected media path')
    if asset['scene'] not in by_scene:p.error('patch adds an unknown film')
    with (a.patch/asset['video']).open('rb') as f:
        if hashlib.file_digest(f,'sha256').hexdigest()!=asset['sha256']:p.error('patch media changed')
a.archive.mkdir(parents=True,exist_ok=False)
shutil.copy2(a.bundle/'manifest.json',a.archive/'manifest.json')
for asset in patch['assets']:
    scene=asset['scene'];old=by_scene[scene]
    for kind in ['video','poster']:
        shutil.move(a.bundle/old[kind],a.archive/old[kind])
        shutil.copy2(a.patch/asset[kind],a.bundle/asset[kind])
    saved=a.archive/'evidence';saved.mkdir(exist_ok=True)
    for path in list((a.bundle/'evidence').glob(scene+'.*'))+list((a.bundle/'evidence').glob(scene+'-[0-9]*.jpg')):
        shutil.move(path,saved/path.name)
    for path in list((a.patch/'evidence').glob(scene+'.*'))+list((a.patch/'evidence').glob(scene+'-[0-9]*.jpg')):
        shutil.copy2(path,a.bundle/'evidence'/path.name)
    by_scene[scene]=asset
base['assets']=[by_scene[x['scene']] for x in base['assets']]
(a.bundle/'manifest.json').write_text(json.dumps(base,ensure_ascii=False,indent=2)+'\n')
# Combine the new film's OCR evidence with the other already-reviewed movies.
old_audit=a.bundle/'evidence/ocr-audit.json';new_audit=a.patch/'evidence/ocr-audit.json'
if old_audit.exists() and new_audit.exists():
    old=json.loads(old_audit.read_text());new=json.loads(new_audit.read_text())
    if new['status']!='passed':raise ValueError('patch OCR audit failed')
    replace={Path(m['movie']).stem:m for m in new['movies']}
    for movie in replace.values():movie['movie']=str(a.bundle/Path(movie['movie']).name)
    old['movies']=[replace.get(Path(m['movie']).stem,m) for m in old['movies']]
    old['status']='passed' if all(m['captionChecks'] and all(c['passed'] for c in m['captionChecks']) and not any(s['matches'] for s in m['samples']) for m in old['movies']) else 'failed'
    old_audit.write_text(json.dumps(old,ensure_ascii=False,indent=2)+'\n')
spec=importlib.util.spec_from_file_location('exporter',Path(__file__).with_name('export.py'))
exporter=importlib.util.module_from_spec(spec);spec.loader.exec_module(exporter)
exporter.gallery(a.bundle,base['assets'])
print('Merged',list(x['scene'] for x in patch['assets']),'into',a.bundle)
