# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
import html
import json
from pathlib import Path

INTERFACE = json.loads((Path(__file__).resolve().parents[1] / "Localization/Interface.json").read_text())

def settings_links(asset):
    settings = asset.get('relatedSettings', [])
    if not settings:
        return ''
    label = html.escape(INTERFACE[asset.get('locale', 'en')]['relatedSettings'])
    links = ''.join(f'<a href="./configuration.html#{html.escape(item["anchor"], quote=True)}"><code>{html.escape(item["key"])}</code></a>' for item in settings)
    return f'<nav class="demo-settings" aria-label="{label}"><span>{label}</span>{links}</nav>'

def collection(section, assets, *, cache_bust=True):
    locale = assets[0].get("locale", "en")
    ui = INTERFACE[locale]
    section_title = ui["sections"][section]
    collection_label = html.escape(ui["collection"].format(name=section_title))
    choose_label = html.escape(ui["choose"].format(name=section_title))
    label = f'{section}-demos'
    slides, tabs = [], []
    for i, a in enumerate(assets):
        name = html.escape(a['scene']); title = html.escape(a['title'])
        token = a['sha256'][:12]
        suffix = '?v=' + token if cache_bust else ''
        video = html.escape(a['video'] + suffix)
        poster = html.escape(a['poster'] + suffix)
        description = html.escape(a.get('description', a['title']))
        duration = f"{int(a['durationSeconds']) // 60}:{int(a['durationSeconds']) % 60:02d}"
        settings_html = settings_links(a)
        slides.append(f'''<article class="demo-slide" id="demo-{name}" aria-labelledby="tab-{name}">
          <video class="demo-video" controls muted playsinline preload="none" poster="{poster}" aria-label="{title}" style="aspect-ratio: {"16 / 5" if a.get("presentation") in ["dual", "dynamic-dual"] else "16 / 10"}">
            <source src="{video}" type="video/mp4" />
            <a href="{video}">{html.escape(ui["watch"].format(title=a["title"]))}</a>
          </video>
          <p class="demo-description">{description}</p>
          {settings_html}
        </article>''')
        tabs.append(f'''<button class="demo-tab" type="button" role="tab" id="tab-{name}" aria-controls="demo-{name}" aria-selected="{'true' if i == 0 else 'false'}" tabindex="{0 if i == 0 else -1}">
          <span class="demo-thumb"><img src="{poster}" loading="lazy" alt="" /><span class="demo-duration">{duration}</span></span>
          <span class="demo-tab-title">{title}</span>
        </button>''')
    return f'''<!-- DEMO-COLLECTION:{section}:START -->
    <div class="demo-gallery" data-count="{len(assets)}" aria-label="{collection_label}" data-play-hint="{html.escape(ui["playHint"])}">
      <div class="demo-gallery-heading"><p class="eyebrow">{html.escape(ui["explore"])}</p>
        <div class="demo-paging"><span class="demo-count" aria-live="polite">1 / {len(assets)}</span>
          <button type="button" class="demo-prev" aria-label="{html.escape(ui["previous"])}">‹</button>
          <button type="button" class="demo-next" aria-label="{html.escape(ui["next"])}">›</button>
        </div>
      </div>
      <div class="demo-stage">{''.join(slides)}</div>
      <div class="demo-tabs" role="tablist" aria-label="{choose_label}">{''.join(tabs)}</div>
    </div>
    <!-- DEMO-COLLECTION:{section}:END -->'''
