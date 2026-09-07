#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Compile this lab's plain string units without requiring full Xcode in the VM."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCALES = ['en', 'ko', 'ja', 'zh-Hans', 'zh-Hant']

def compile_catalog(output):
    catalog = json.loads((ROOT/'Localization/Localizable.xcstrings').read_text())
    rendered = {}
    for locale in LOCALES:
        lines = ['/* Generated from Localizable.xcstrings. Do not edit. */']
        for key, entry in sorted(catalog['strings'].items()):
            translation = entry['localizations'][locale]
            if set(translation) != {'stringUnit'} or translation['stringUnit']['state'] != 'translated':
                raise ValueError(f'Expected a reviewed plain string unit: {locale} / {key}')
            value = translation['stringUnit']['value']
            lines.append(f'{json.dumps(key, ensure_ascii=False)} = {json.dumps(value, ensure_ascii=False)};')
        rendered[locale] = '\n'.join(lines)+'\n'
    for locale, text in rendered.items():
        directory = output/(locale+'.lproj')
        directory.mkdir(parents=True, exist_ok=True)
        temporary = directory/'Localizable.strings.tmp'
        temporary.write_text(text)
        temporary.replace(directory/'Localizable.strings')
    print(f'Compiled {len(catalog["strings"])} strings in {len(LOCALES)} locales')

if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output',type=Path,default=ROOT/'.build/DemoLab/Localization')
    compile_catalog(p.parse_args().output)
