#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Install reviewed locale bundles into the checkout; never push or deploy."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT=Path(__file__).resolve().parents[2]
LOCALES=['en','ko','ja','zh-Hans','zh-Hant']
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('bundle',type=Path)
p.add_argument('--all-locales',action='store_true')
a=p.parse_args()
expected={x['scene'] for x in json.loads((ROOT/'DemoLab/publication.json').read_text())['assets']}
bundles=[a.bundle/locale for locale in LOCALES] if a.all_locales else [a.bundle]
validated=[]
for bundle in bundles:
    manifest=json.loads((bundle/'manifest.json').read_text());locale=manifest.get('locale','en')
    if locale not in LOCALES:p.error('unsupported bundle locale')
    if a.all_locales and bundle.name!=locale:p.error('bundle directory and locale disagree')
    if {x['scene'] for x in manifest['assets']}!=expected:p.error('each locale must contain every publication asset')
    for asset in manifest['assets']:
        for kind,suffix in [('video','.mp4'),('poster','.jpg')]:
            if asset[kind]!=asset['scene']+suffix or not (bundle/asset[kind]).is_file():p.error('missing or unexpected media path')
        with (bundle/asset['video']).open('rb') as file:
            if hashlib.file_digest(file,'sha256').hexdigest()!=asset['sha256']:p.error('movie changed after verification')
        scene=ROOT/'DemoLab/scenes'/f"{asset['scene']}.json" if locale=='en' else ROOT/'DemoLab/scenes'/locale/f"{asset['scene']}.json"
        if hashlib.sha256(scene.read_bytes()).hexdigest()!=asset.get('sceneSHA256'):p.error('scene changed after export')
    validated.append((bundle,locale,manifest))
for bundle,locale,manifest in validated:
    target=ROOT/'web' if locale=='en' else ROOT/'web/media'/locale
    target.mkdir(parents=True,exist_ok=True)
    for asset in manifest['assets']:
        for kind in ['video','poster']:shutil.copy2(bundle/asset[kind],target/asset[kind])
    shutil.copy2(bundle/'manifest.json',target/('demo-manifest.json' if locale=='en' else 'manifest.json'))
if any(locale=='en' for _,locale,_ in validated):
    subprocess.run(['python3',str(ROOT/'DemoLab/scripts/render-site.py')],check=True)
print(f'Installed {len(validated)} reviewed locales locally in web/')
