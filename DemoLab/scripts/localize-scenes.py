#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Compile localized narration, real input, and AX assertions from reviewed catalogs."""
from pathlib import Path
import copy
import json
import re

ROOT = Path(__file__).resolve().parents[1]
LOCALES = ['en', 'ko', 'ja', 'zh-Hans', 'zh-Hant']

def read_catalog(path):
    raw = json.loads(path.read_text())['strings']
    return {key: {locale: entry.get('localizations', {}).get(locale, {}).get('stringUnit', {}).get('value', '')
                  for locale in LOCALES} for key, entry in raw.items()}


def compile_scenes():
    app = read_catalog(ROOT / 'Localization/Localizable.xcstrings')
    film = json.loads((ROOT / 'Localization/Films.json').read_text())['strings']
    product = read_catalog(ROOT.parent / 'Tatami/Resources/Localizable.xcstrings')
    product_by_english = {values['en'] or key: values for key, values in product.items()}
    names = set(re.findall(r'^name = "([^"]+)"', (ROOT / 'config/tatami-demo.toml.in').read_text(), re.M))
    names |= {'Design review', 'Writing', 'Conversation', 'Quick notes'}
    def translated(text, locale):
        values = film.get(text) or app.get(text)
        if not values or not values.get(locale):
            raise ValueError(f'Missing {locale} film/input text: {text}')
        return values[locale]

    def native(text, locale):
        if text in names: return text
        values = product_by_english.get(text)
        if values and values.get(locale): return values[locale]
        # Runtime progress indicators retain the same numeric arguments while
        # their complete, localized sentence may reorder those arguments.
        for english, values in product_by_english.items():
            normalized = re.sub(r'%\d+\$lld', '%lld', english)
            if '%lld' not in normalized: continue
            pattern = re.escape(normalized).replace('%lld', r'(\d+)')
            match = re.fullmatch(pattern, text)
            if match and values.get(locale):
                arguments = list(match.groups()); index = 0
                def substitute(m):
                    nonlocal index
                    position = int(m.group(1)) - 1 if m.group(1) else index
                    index += 1
                    return arguments[position]
                return re.sub(r'%(?:(\d+)\$)?lld', substitute, values[locale])
        raise ValueError(f'Missing native AX translation {locale}: {text}')

    assets = json.loads((ROOT / 'publication.json').read_text())['assets']
    for locale in LOCALES[1:]:
        destination = ROOT / 'scenes' / locale
        destination.mkdir(exist_ok=True)
        for asset in assets:
            scene = json.loads((ROOT / 'scenes' / (asset['scene'] + '.json')).read_text())
            scene['title'] = translated(asset['title'], locale)
            scene['summary'] = translated(asset['description'], locale)
            for step in scene.get('setup', []) + scene['steps']:
                kind = step['kind']
                if kind in ['caption', 'chapter'] and step['text']:
                    step['text'] = translated(step['text'], locale)
                if kind == 'typeText' and step.get('app') != 'Terminal':
                    step['text'] = translated(step['text'], locale)
                if step.get('app') == 'Tatami' and 'identifier' in step:
                    prefix, sep, text = step['identifier'].partition(':')
                    if sep and prefix in ['text', 'description', 'title', 'help', 'button', 'heading']:
                        step['identifier'] = prefix + ':' + native(text, locale)
                        if kind == 'expectValue': step['value'] = native(step['value'], locale)
                elif kind == 'expectValue' and step['value'] in app.keys() | film.keys():
                    step['value'] = translated(step['value'], locale)
                elif kind == 'expectStory' and step['field'] in ['headline','lastTask','lastMessage','reviewComment']:
                    step['value'] = translated(step['value'], locale)
            (destination / (asset['scene'] + '.json')).write_text(json.dumps(scene, ensure_ascii=False, indent=2) + '\n')
    print(f'Compiled {len(assets)} scenes in {len(LOCALES)-1} additional locales')

if __name__ == '__main__': compile_scenes()
