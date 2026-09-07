#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Generate localized current documentation with stable links and source anchors."""
import argparse
import json
import os
from pathlib import Path
import re
from urllib.parse import urlsplit,urlunsplit,unquote
from localization import ROOT,LOCALES,NAMES,TextCatalog,markdown_units

DOCUMENTS = [Path('README.md'), *[p.relative_to(ROOT) for p in sorted((ROOT/'docs').glob('*.md'))], Path('DemoLab/README.md'),
             *[p.relative_to(ROOT) for p in sorted((ROOT/'DemoLab/docs').glob('*.md'))],Path('NOTICE.md'), Path('THIRD_PARTY_NOTICES.md')]
NAV = re.compile(r'\n?<!-- LANGUAGE-LINKS:START -->.*?<!-- LANGUAGE-LINKS:END -->\n?',re.S)


def destination(source, locale):
    if locale=='en': return source
    if source.parent==Path('.'): return source.with_name(source.stem+'.'+locale+source.suffix)
    return source.parent/locale/source.name


def language_links(source, locale):
    current=destination(source,locale)
    links=[]
    for code in LOCALES:
        path=os.path.relpath(destination(source,code), current.parent)
        links.append(f'[{NAMES[code]}]({path})')
    return '<!-- LANGUAGE-LINKS:START -->\n'+' · '.join(links)+'\n<!-- LANGUAGE-LINKS:END -->\n\n'


def headings(source):
    result=[];fence=None;used={}
    for line in source.splitlines():
        m=re.match(r'^\s*(`{3,}|~{3,})',line)
        if m:
            fence=None if fence==m[1][0] else m[1][0];continue
        if fence:continue
        match=re.match(r'^#{1,6}\s+(.+)',line)
        if match:
            label=re.sub(r'<[^>]+>','',match[1])
            slug=re.sub(r'[^\w\s-]','',label.lower()).strip().replace(' ','-')
            count=used.get(slug,0);used[slug]=count+1
            result.append(slug+(f'-{count}' if count else ''))
    return result


def anchor_headings(translated, anchors):
    result=[];index=0;fence=None
    for line in translated.splitlines():
        m=re.match(r'^\s*(`{3,}|~{3,})',line)
        if m:fence=None if fence==m[1][0] else m[1][0]
        if not fence and re.match(r'^#{1,6}\s',line):
            result.append(f'<a id="{anchors[index]}"></a>');index+=1
        result.append(line)
    if index!=len(anchors):raise ValueError('Changed documentation heading count')
    return '\n'.join(result)+'\n'


def rewrite_links(text, source, locale):
    target=destination(source,locale)
    def url(value):
        parts=urlsplit(value)
        if parts.netloc=='pangmo5.dev' and (parts.path=='/Tatami' or parts.path.startswith('/Tatami/')):
            tail=parts.path.removeprefix('/Tatami').lstrip('/')
            return urlunsplit(parts._replace(path='/Tatami/'+locale+'/'+tail))
        if parts.scheme or parts.netloc or not parts.path:return value
        absolute=(ROOT/source.parent/unquote(parts.path)).resolve()
        try:relative=absolute.relative_to(ROOT)
        except ValueError:return value
        localized=destination(relative,locale) if relative in DOCUMENTS and relative != Path('THIRD_PARTY_NOTICES.md') else relative
        if relative.parent==Path('web') and relative.suffix=='.jpg':localized=Path('web/media')/locale/relative.name
        path=os.path.relpath(localized,target.parent)
        return urlunsplit(parts._replace(path=path))
    result=[];fence=None
    for line in text.splitlines():
        marker=re.match(r'^\s*(`{3,}|~{3,})',line)
        if marker:
            fence=None if fence==marker[1][0] else marker[1][0];result.append(line);continue
        if fence:result.append(line);continue
        line=re.sub(r'(?<=\]\()([^\s)]+)(?=\))',lambda m:url(m[0]),line)
        line=re.sub(r'\b(href|src)="([^"]+)"',lambda m:m[1]+'="'+url(m[2])+'"',line)
        line=re.sub(r'^(\[[^]]+\]:\s*)(\S+)',lambda m:m[1]+url(m[2]),line)
        result.append(line)
    return '\n'.join(result)+'\n'


def build(selected=None):
    values=json.loads((ROOT/'Localization/Docs.json').read_text())
    documents=[p for p in DOCUMENTS if selected is None or str(p) in selected]
    outputs={}
    for source in documents:
        text=NAV.sub('',(ROOT/source).read_text()).lstrip('\n')
        localized_source=(ROOT/'Localization/ThirdPartyNotice.md').read_text() if source==Path('THIRD_PARTY_NOTICES.md') else text
        for locale in LOCALES[1:]:
            catalog=TextCatalog(values=values,locale=locale)
            translated=markdown_units(localized_source,catalog,str(source))
            translated=anchor_headings(translated,headings(localized_source))
            outputs[destination(source,locale)]=language_links(source,locale)+rewrite_links(translated,source,locale)
        outputs[source]=language_links(source,'en')+text
    # No partial publication if any translation/placeholder failed above.
    for path,text in outputs.items():
        target=ROOT/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_text(text)
    print(f'Generated {len(documents)} documents in {len(LOCALES)} languages')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--documents',nargs='+');build(p.parse_args().documents)
