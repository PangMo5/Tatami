# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
import html

def collection(section, assets):
    label = f'{section}-demos'
    slides, tabs = [], []
    for i, a in enumerate(assets):
        name = html.escape(a['scene']); title = html.escape(a['title'])
        token = a['sha256'][:12]
        video = html.escape(a['video'] + '?v=' + token)
        poster = html.escape(a['poster'] + '?v=' + token)
        description = html.escape(a.get('description', a['title']))
        duration = f"{int(a['durationSeconds']) // 60}:{int(a['durationSeconds']) % 60:02d}"
        slides.append(f'''<article class="demo-slide" id="demo-{name}" aria-labelledby="tab-{name}">
          <video class="demo-video" controls muted playsinline preload="none" poster="{poster}" aria-label="{title}" style="aspect-ratio: {"12 / 5" if a.get("presentation")=="dual" else "16 / 10"}">
            <source src="{video}" type="video/mp4" />
            <a href="{video}">Watch {title}</a>
          </video>
          <p class="demo-description">{description}</p>
        </article>''')
        tabs.append(f'''<button class="demo-tab" type="button" role="tab" id="tab-{name}" aria-controls="demo-{name}" aria-selected="{'true' if i == 0 else 'false'}" tabindex="{0 if i == 0 else -1}">
          <span class="demo-thumb"><img src="{poster}" loading="lazy" alt="" /><span class="demo-duration">{duration}</span></span>
          <span class="demo-tab-title">{title}</span>
        </button>''')
    return f'''<!-- DEMO-COLLECTION:{section}:START -->
    <div class="demo-gallery" data-count="{len(assets)}" aria-label="{section} video collection">
      <div class="demo-gallery-heading"><p class="eyebrow">Explore the workflow</p>
        <div class="demo-paging"><span class="demo-count" aria-live="polite">1 / {len(assets)}</span>
          <button type="button" class="demo-prev" aria-label="Previous video">‹</button>
          <button type="button" class="demo-next" aria-label="Next video">›</button>
        </div>
      </div>
      <div class="demo-stage">{''.join(slides)}</div>
      <div class="demo-tabs" role="tablist" aria-label="Choose a {section} demonstration">{''.join(tabs)}</div>
    </div>
    <!-- DEMO-COLLECTION:{section}:END -->'''

