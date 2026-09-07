// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
(async () => {
  const content = document.getElementById('content');
  const fail = () => {
    const message = document.createElement('p');
    message.className = 'state';
    message.textContent = content.dataset.loadError + ' ';
    const link = document.createElement('a');
    link.href = content.dataset.sourceUrl;
    link.textContent = 'GitHub';
    message.append(link);
    content.replaceChildren(message);
  };
  try {
    if (typeof marked === 'undefined' || typeof DOMPurify === 'undefined') throw new Error('Markdown renderer unavailable');
    const response = await fetch(content.dataset.documentSrc, {cache:'no-cache'});
    if (!response.ok) throw new Error(`Document request failed: ${response.status}`);
    content.innerHTML = DOMPurify.sanitize(marked.parse(await response.text()));
    const supported = ['en','ko','ja','zh-Hans','zh-Hant'];
    const siteRoot = new URL(document.documentElement.lang === 'en' ? './' : '../', location.href);
    for (const link of content.querySelectorAll('a[href]')) {
      const href = link.getAttribute('href');
      if (!href || href.startsWith('#')) continue;
      if (/^[a-z][a-z0-9+.-]*:/i.test(href)) {
        const published = new URL(href);
        if (published.origin === 'https://pangmo5.dev' && published.pathname.startsWith('/Tatami/')) {
          const target = new URL(published.pathname.slice('/Tatami/'.length), siteRoot);
          target.hash = published.hash; target.search = published.search; link.href = target.href;
        }
        continue;
      }
      const source = new URL(href, content.dataset.sourceUrl);
      const parts = source.pathname.split('/');
      const name = parts.at(-1);
      const page = { 'CLI.md':'cli.html', 'CONFIGURATION.md':'configuration.html' }[name];
      if (page) {
        const candidate = parts.at(-2);
        const language = supported.includes(candidate) ? candidate : 'en';
        const target = new URL((language === 'en' ? '' : language+'/')+page, siteRoot);
        target.hash = source.hash; link.href = target.href;
      } else link.href = source.href;
    }
    for (const table of content.querySelectorAll('table')) {
      const labels = [...table.querySelectorAll('thead th')].map(h=>h.textContent);
      table.setAttribute('role','table');
      for (const row of table.querySelectorAll('tbody tr')) {
        row.setAttribute('role','row');
        [...row.cells].forEach((cell,i)=>{ cell.dataset.label=labels[i] || ''; cell.setAttribute('role','cell'); });
      }
      const wrapper = document.createElement('div'); wrapper.className='doc-table';
      table.before(wrapper); wrapper.append(table);
    }
    const side = document.getElementById('side');
    const navigation = document.getElementById('side-nav');
    const used = new Set();
    const headings = [...content.querySelectorAll('h2,h3')];
    for (const heading of headings) {
      const previous = heading.previousElementSibling;
      const marker = previous?.tagName === 'A' ? previous : previous?.tagName === 'P' && !previous.textContent.trim() ? previous.querySelector('a[id]') : null;
      let id = marker?.id ? marker.id : heading.textContent.toLowerCase().trim().replace(/[^\p{L}\p{N}\s-]/gu,'').replace(/\s+/g,'-');
      if (marker?.id) {
        if (previous.tagName === 'P') previous.remove(); else marker.remove();
      }
      id = id || 'section';
      const base = id; let suffix = 1;
      while (used.has(id)) id = `${base}-${suffix++}`;
      used.add(id); heading.id = id;
      const link = document.createElement('a');
      link.href = '#'+id; link.textContent = heading.textContent;
      link.className = heading.tagName === 'H3' ? 'lvl-3' : 'lvl-2';
      link.dataset.target = id; navigation.append(link);
    }
    side.hidden = headings.length === 0;
    const links = [...navigation.querySelectorAll('a')];
    const observer = new IntersectionObserver(entries => {
      for (const entry of entries) if (entry.isIntersecting) {
        for (const link of links) link.classList.toggle('active',link.dataset.target === entry.target.id);
      }
    }, {rootMargin:'-64px 0px -70% 0px'});
    headings.forEach(heading => observer.observe(heading));
    if (location.hash) document.getElementById(decodeURIComponent(location.hash.slice(1)))?.scrollIntoView();
  } catch (error) { fail(); }
})();
