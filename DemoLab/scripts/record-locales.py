#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Record missing or changed actions independently for each display language."""
from pathlib import Path
import argparse
import json
import subprocess
import sys
from narration import verified_scenes

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--round',type=int,default=1)
parser.add_argument('--locales',nargs='+',choices=['en','ko','ja','zh-Hans','zh-Hant'],default=['en','ko','ja','zh-Hans','zh-Hant'])
args=parser.parse_args()
assets=json.loads((ROOT/'publication.json').read_text())['assets']
summary=[]
for locale in args.locales:
    missing=[]
    for asset in assets:
        name=asset['scene'];accepted=False
        for folder in (ROOT/'recordings').glob('v[0-9]*'):
            files=list(folder.glob(name+'-[0-9].take.json')) if asset.get('presentation')=='dual' else list(folder.glob(name+'.take.json'))
            if len(files)!=(2 if asset.get('presentation')=='dual' else 1):continue
            rows=[json.loads(p.read_text()) for p in files]
            if all(r.get('locale')==locale and r['status']=='passed' and r['frames']>0 and r['droppedFrames']/r['frames']<=.01 for r in rows):
                try:
                    for file, record in zip(files, rows):
                        verified_scenes(file.with_name(file.name.removesuffix('.take.json')+'.mov'), dict(asset, locale=locale), record)
                    if asset.get('presentation')=='dynamic-dual':
                        extra=json.loads((folder/(name+'.secondary.json')).read_text())
                        if extra['frames']<=0 or extra['droppedFrames']/extra['frames']>.01:continue
                except (ValueError, OSError):continue
                accepted=True;break
        if not accepted:missing.append(name)
    print(f'LOCALE {locale}: {len(assets)-len(missing)} accepted, {len(missing)} to record',flush=True)
    if not missing:continue
    output=ROOT/'recordings'/f'v6-library-{locale}-{args.round}'
    result=subprocess.run([sys.executable,str(ROOT/'scripts/capture.py'),'--locale',locale,'--output',str(output),'--continue-on-error','--scenes',*missing])
    summary.append({'locale':locale,'output':str(output),'exitCode':result.returncode})
print(json.dumps(summary,indent=2),flush=True)
raise SystemExit(1 if any(r['exitCode'] for r in summary) else 0)
