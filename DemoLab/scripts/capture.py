#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Capture independent publication scenes on the recording machine."""
from pathlib import Path
import argparse
import json
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--scenes', nargs='+')
parser.add_argument('--continue-on-error', action='store_true', help='keep failed takes, cleanly seed the next independent scene, and exit nonzero at the end')
args = parser.parse_args()
assets = json.loads((ROOT/'publication.json').read_text())['assets']
if args.scenes:
    unknown = set(args.scenes) - {a['scene'] for a in assets}
    if unknown:
        parser.error(f'unknown scenes: {sorted(unknown)}')
    assets = [a for a in assets if a['scene'] in args.scenes]
args.output.mkdir(parents=True, exist_ok=True)
for asset in assets:
    name = asset['scene']
    if list(args.output.glob(name+'.*')) or list(args.output.glob(name+'-[0-9].*')):
        parser.error(f'existing take: {name}; use a new output directory')
env = dict(os.environ, DEMOLAB_NO_BUILD='1')

def ctl(*parts):
    subprocess.run([str(ROOT/'bin/democtl'), *parts], check=True, env=env)

results = []
try:
    for asset in assets:
        name = asset['scene']
        print('\nCAPTURE', name, flush=True)
        try:
            ctl('reset')
            ctl('display', 'disconnect')
            if asset.get('presentation') == 'dual':
                ctl('display', 'connect')
            ctl('seed', *asset.get('seedOptions', []))
            ctl('take', name, '--display', 'all' if asset.get('presentation') == 'dual' else 'main',
                '--output', str(args.output.resolve()/(name+'.mov')))
            records = list(args.output.glob(name+'*.take.json'))
            if len(records) != (2 if asset.get('presentation') == 'dual' else 1):
                raise ValueError('missing capture manifests')
            for file in records:
                record = json.loads(file.read_text())
                if record['status'] != 'passed' or record['frames'] <= 0 or record['droppedFrames']/record['frames'] > .01:
                    raise ValueError(f'capture quality failed: {file.name}')
            results.append(dict(scene=name, status='passed'))
        except (subprocess.CalledProcessError, ValueError) as error:
            results.append(dict(scene=name, status='failed', error=str(error)))
            print('CAPTURE FAILED:', name, error, flush=True)
            if not args.continue_on_error:
                break
        finally:
            (args.output/'capture-report.json').write_text(json.dumps(results, indent=2)+'\n')
finally:
    ctl('quit')
    ctl('display', 'disconnect')
failures = [r for r in results if r['status'] != 'passed']
print(f'Capture result: {len(results)-len(failures)} passed, {len(failures)} failed. {args.output}')
raise SystemExit(1 if failures else 0)
