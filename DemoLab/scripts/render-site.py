#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Render accessible, visible video collections from the accepted asset manifest."""
from pathlib import Path
import html
import json
import re
ROOT = Path(__file__).resolve().parents[2]


from video_gallery import collection, settings_links


def render():
    manifest = json.loads((ROOT / 'web/demo-manifest.json').read_text())
    contract = json.loads((ROOT / 'DemoLab/publication.json').read_text())
    planned = {a['scene']: a for a in contract['assets']}
    groups = {}
    for a in manifest['assets']:
        if a['scene'] == 'tour': continue
        a = dict(a, **{k:v for k,v in planned.get(a['scene'],{}).items() if k in ['title','description','section']})
        groups.setdefault(a['section'], []).append(a)
    page = ROOT / 'web/index.html'
    text = page.read_text()
    text = re.sub(r'\s*<!-- DEMO-COLLECTION:.*?:START -->.*?<!-- DEMO-COLLECTION:.*?:END -->', '', text, flags=re.S)
    text = re.sub(r'\s*<details class="more-demo">.*?</details>', '', text, flags=re.S)
    text = re.sub(r'\s*<figure class="feature-demo".*?</figure>', '', text, flags=re.S)
    for section, assets in groups.items():
        match = re.search(r'<section\b[^>]*\bid="'+re.escape(section)+r'"[^>]*>',text)
        if not match: raise ValueError(f'No section for {section}')
        end = text.index('</section>',match.end())
        region = text[match.end():end]
        # Keep section introduction, then the collection, then feature explanations.
        paragraph = re.search(r'<p class="sub">.*?</p>',region,re.S)
        if paragraph:
            pos=match.end()+paragraph.end()
        else:
            pos=match.end()+region.rfind('</div>')
        text=text[:pos]+'\n    '+collection(section,assets)+text[pos:]
    if 'src="./demos.js"' not in text:
        text=text.replace('</body>','<script src="./demos.js" defer></script>\n</body>')
    # The hero is outside the generated collections but shares their media cache key.
    hero = next(a for a in manifest['assets'] if a['scene'] == 'tour')
    text = re.sub(r'<!-- DEMO-SETTINGS:tour:START -->.*?<!-- DEMO-SETTINGS:tour:END -->',
                  '<!-- DEMO-SETTINGS:tour:START -->'+settings_links(hero)+'<!-- DEMO-SETTINGS:tour:END -->',text,flags=re.S)
    for name in [hero['video'], hero['poster']]:
        text = re.sub(re.escape(name) + r'(?:\?v=[a-f0-9]+)?', name + '?v=' + hero['sha256'][:12], text)
    page.write_text(text)
    print('Collections:',', '.join(f'{name} ({len(values)})' for name,values in groups.items()))

if __name__ == '__main__': render()
