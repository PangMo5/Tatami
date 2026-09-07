# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Revise words on clean originals without changing recorded actions or clocks."""
import copy
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def capture_contract(scene):
    result = copy.deepcopy(scene)
    result.pop('title', None)
    result.pop('summary', None)
    for step in result.get('setup', []) + result['steps']:
        if step['kind'] in ['caption', 'chapter']:
            step['text'] = bool(step['text'])
    return result


def current_scene(asset):
    locale = asset.get('locale', 'en')
    return ROOT / 'scenes' / ('' if locale == 'en' else locale) / (asset['scene'] + '.json')


def verified_scenes(movie, asset, record):
    if movie.with_suffix('.rejected.json').exists():
        raise ValueError(f'{movie}: take rejected during visual review')
    frozen = movie.with_suffix('.scene.json')
    if not frozen.is_file() or hashlib.sha256(frozen.read_bytes()).hexdigest() != record['sceneSHA256']:
        raise ValueError(f'{movie}: scene changed or frozen capture scene is missing')
    old = json.loads(frozen.read_text())
    new = json.loads(current_scene(asset).read_text())
    if capture_contract(old) != capture_contract(new):
        raise ValueError(f'{movie}: scene changed its actions or timing; re-record before exporting')
    return old, new


def revised_timeline(movie, asset, record):
    old, new = verified_scenes(movie, asset, record)
    timeline = json.loads(movie.with_suffix('.timeline.json').read_text())
    for track in ['chapter', 'caption']:
        replacements = {}
        for before, after in zip(old['steps'], new['steps'], strict=True):
            if before['kind'] != track or not before['text']:
                continue
            existing = replacements.setdefault(before['text'], after['text'])
            if existing != after['text']:
                raise ValueError(f'{movie}: repeated narration has ambiguous revisions')
        for event in timeline['events']:
            if event['track'] == track and event['text']:
                if event['text'] not in replacements:
                    raise ValueError(f'{movie}: timeline narration does not match its capture scene')
                event['text'] = replacements[event['text']]
    return timeline


def escaped(text):
    text = text.replace('{', '｛').replace('}', '｝')
    text = re.sub(r'\\([Nnh])', r'\\{}\1', text)
    return text.replace('\r\n', '\\N').replace('\n', '\\N').replace('\r', '\\N')


def timestamp(seconds):
    total = round(max(0, seconds) * 100)
    return f'{total // 360000}:{total // 6000 % 60:02}:{total // 100 % 60:02}.{total % 100:02}'


def revise_ass(original, timeline):
    # Keycasts retain the recorder's actual input and formatting, byte for byte.
    lines = [line for line in original.splitlines()
             if not (line.startswith('Dialogue: ') and line.split(',', 4)[3] in ['Caption', 'Chapter'])]
    for event in timeline['events']:
        if event['track'] not in ['caption', 'chapter'] or not event['text']:
            continue
        text = escaped(event['text']).replace(' | ', '\\N')
        start, end = timestamp(event['start']), timestamp(max(event['end'], event['start'] + .01))
        lines.append(f'Dialogue: 0,{start},{end},{event["track"].title()},,0,0,0,,{{\\fad(100,100)}}{text}')
    return '\n'.join(lines) + '\n'
