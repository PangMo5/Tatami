#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Install a complete, reviewed export into the local marketing site. Does not publish."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('bundle', type=Path)
args = parser.parse_args()
manifest = json.loads((args.bundle / 'manifest.json').read_text())
contract = json.loads((root / 'DemoLab/publication.json').read_text())
if {a['scene'] for a in manifest['assets']} != {a['scene'] for a in contract['assets']}:
    parser.error('the bundle must contain every publication asset')
for asset in manifest['assets']:
    movie = args.bundle / asset['video']
    if asset['video'] != asset['scene'] + '.mp4' or asset['poster'] != asset['scene'] + '.jpg' or not (args.bundle / asset['poster']).is_file():
        parser.error('unexpected or missing media')
    with movie.open('rb') as file:
        if hashlib.file_digest(file, 'sha256').hexdigest() != asset['sha256']:
            parser.error(f'{movie} changed after verification')
# Retire only files named by the previous local manifest, keeping a review copy.
previous = root / 'web/demo-manifest.json'
if previous.exists():
    old = json.loads(previous.read_text())
    current = {a[key] for a in manifest['assets'] for key in ['video', 'poster']}
    for asset in old['assets']:
        for key in ['video', 'poster']:
            name = asset[key]
            if Path(name).name != name:
                parser.error('previous manifest contains a non-local media path')
            path = root / 'web' / name
            if name not in current and path.is_file():
                archive = args.bundle / 'retired-site-media'
                archive.mkdir(exist_ok=True)
                shutil.move(path, archive / name)
for asset in manifest['assets']:
    for key in ['video', 'poster']:
        shutil.copy2(args.bundle / asset[key], root / 'web' / asset[key])
shutil.copy2(args.bundle / 'manifest.json', root / 'web/demo-manifest.json')
import subprocess
subprocess.run(['python3',str(root/'DemoLab/scripts/render-site.py')],check=True)
print('Installed locally in web/. Review README and the site before any separate publication.')
