#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Build all language routes from reviewed copy, current docs and accepted films."""
import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
import sys
from urllib.parse import urlsplit
from localization import ROOT,LOCALES,NAMES,Node,TextCatalog,translate_html

sys.path.insert(0,str(ROOT/'DemoLab/scripts'))
from video_gallery import collection

COLLECTION=re.compile(r'<!-- DEMO-COLLECTION:([^:]+):START -->.*?<!-- DEMO-COLLECTION:\1:END -->',re.S)
PAGES=['index.html','cli.html','configuration.html','releases.html']


def sha(path):
    digest=hashlib.sha256()
    with path.open('rb') as file:
        for chunk in iter(lambda:file.read(1024*1024),b''):digest.update(chunk)
    return digest.hexdigest()


def locale_manifest(locale):
    directory=ROOT/'web' if locale=='en' else ROOT/'web/media'/locale
    path=directory/('demo-manifest.json' if locale=='en' else 'manifest.json')
    manifest=json.loads(path.read_text())
    if manifest.get('locale','en')!=locale:raise ValueError(f'Wrong media locale: {path}')
    expected={a['scene'] for a in json.loads((ROOT/'DemoLab/publication.json').read_text())['assets']}
    if {a['scene'] for a in manifest['assets']}!=expected:raise ValueError(f'Incomplete media collection: {locale}')
    for asset in manifest['assets']:
        for kind,suffix in [('video','.mp4'),('poster','.jpg')]:
            if asset[kind]!=asset['scene']+suffix or not (directory/asset[kind]).is_file():raise ValueError(f'Missing media: {locale}/{asset[kind]}')
        if sha(directory/asset['video'])!=asset['sha256']:raise ValueError(f'Media hash mismatch: {locale}/{asset["scene"]}')
        source=ROOT/'DemoLab/scenes'/asset['scene'] if locale=='en' else ROOT/'DemoLab/scenes'/locale/asset['scene']
        if asset.get('sceneSHA256')!=sha(source.with_suffix('.json')):raise ValueError(f'Stale scene in published media: {locale}/{asset["scene"]}')
    return directory,manifest


def media_url(asset,kind,locale):
    return asset[kind] if locale=='en' else '../media/'+locale+'/'+asset[kind]


def page_link(page,locale,from_locale):
    prefix='../' if from_locale!='en' else './'
    return prefix+(locale+'/' if locale!='en' else '')+page


def build(output,version,locales):
    values=json.loads((ROOT/'Localization/Web.json').read_text())
    manifests={locale:locale_manifest(locale) for locale in locales}
    generated={}
    for locale in locales:
        directory,manifest=manifests[locale]
        groups={}
        for asset in manifest['assets']:
            if asset['scene']=='tour':continue
            local=dict(asset,locale=locale,video=media_url(asset,'video',locale),poster=media_url(asset,'poster',locale))
            groups.setdefault(asset['section'],[]).append(local)
        for page in PAGES:
            source=(ROOT/'web'/page).read_text()
            source=COLLECTION.sub(lambda m:'<div data-collection="'+m[1]+'"></div>',source)
            document=translate_html(source,TextCatalog(values=values,locale=locale),'web/'+page)
            def walk(node):
                if not isinstance(node,Node):return
                if node.tag=='html':node.attrs['lang']=locale
                if node.tag=='video' and 'poster' in node.attrs:
                    name=Path(urlsplit(node.attrs['poster']).path).stem
                    asset=next(a for a in manifest['assets'] if a['scene']==name)
                    node.attrs['poster']=media_url(asset,'poster',locale)+'?v='+asset['sha256'][:12]
                if node.tag=='source' and node.attrs.get('type')=='video/mp4':
                    name=Path(urlsplit(node.attrs['src']).path).stem
                    asset=next(a for a in manifest['assets'] if a['scene']==name)
                    node.attrs['src']=media_url(asset,'video',locale)+'?v='+asset['sha256'][:12]
                for attribute in ['src','href']:
                    value=node.attrs.get(attribute,'');name=Path(urlsplit(value).path).name
                    if name in ['style.css','demos.js','docs.js','site.js','icon.png'] and not urlsplit(value).scheme:
                        prefix='./' if locale=='en' else '../'
                        token=sha(ROOT/'web'/name)[:12] if name!='icon.png' else sha(ROOT/'Resources/Marketing/app-icon.png')[:12]
                        node.attrs[attribute]=prefix+name+'?v='+token
                if 'data-document-src' in node.attrs:
                    name=Path(node.attrs['data-document-src']).name
                    node.attrs['data-document-src']=('./' if locale=='en' else '../')+'content/'+locale+'/'+name
                    if locale!='en':node.attrs['data-source-url']=node.attrs['data-source-url'].replace('/docs/','/docs/'+locale+'/')
                if node.tag=='a' and node.attrs.get('href','').endswith(('/docs/CLI.md','/docs/CONFIGURATION.md')):
                    node.attrs['href']=('../' if locale!='en' else './')+'content/'+locale+'/'+Path(node.attrs['href']).name
                if node.tag=='a' and locale!='en':
                    for notice in ['NOTICE','THIRD_PARTY_NOTICES']:
                        if node.attrs.get('href','').endswith('/'+notice+'.md'):
                            node.attrs['href']=node.attrs['href'].removesuffix('.md')+'.'+locale+'.md'
                for child in node.children:walk(child)
                if node.tag=='div' and node.attrs.get('class')=='nav-inner':
                    picker=Node('select',{'data-language-picker':'','aria-label':TextCatalog(values=values,locale=locale).text('Language','language picker'),'class':'language-picker'})
                    for code in LOCALES:
                        attrs={'value':page_link(page,code,locale)}
                        if code==locale:attrs['selected']=None
                        picker.children.append(Node('option',attrs,[NAMES[code]]))
                    node.children.append(picker)
                if node.tag=='div' and node.attrs.get('class')=='footer-inner':
                    links=Node('nav',{'class':'language-links','aria-label':TextCatalog(values=values,locale=locale).text('Language','language links')})
                    for code in LOCALES:
                        attrs={'href':page_link(page,code,locale),'data-language-link':''}
                        if code==locale:attrs['aria-current']='page'
                        links.children.append(Node('a',attrs,[NAMES[code]]))
                    node.children.append(links)
                if node.tag=='head':
                    for code in LOCALES:
                        url='https://pangmo5.dev/Tatami/'+(code+'/' if code!='en' else '')+('' if page=='index.html' else page)
                        node.children.append(Node('link',{'rel':'alternate','hreflang':code,'href':url}))
                    url='https://pangmo5.dev/Tatami/'+(locale+'/' if locale!='en' else '')+('' if page=='index.html' else page)
                    node.children.append(Node('link',{'rel':'canonical','href':url}))
            walk(document)
            text=document.render().replace('__VERSION__',version)
            text=re.sub(r'<div data-collection="([^"]+)"></div>',lambda m:collection(m[1],groups[m[1]]),text)
            generated[(Path(locale) if locale!='en' else Path())/page]=text
    # Validate all inputs before writing the site directory.
    for locale in locales:
        for name in ['CLI.md','CONFIGURATION.md']:
            file=ROOT/'docs'/name if locale=='en' else ROOT/'docs'/locale/name
            if not file.is_file():raise ValueError(f'Missing localized document: {file}')
    output.mkdir(parents=True,exist_ok=True)
    for p in (ROOT/'web').iterdir():
        if p.suffix in ['.css','.js']:shutil.copy2(p,output/p.name)
    shutil.copy2(ROOT/'Resources/Marketing/app-icon.png',output/'icon.png')
    for locale,(directory,manifest) in manifests.items():
        target=output if locale=='en' else output/'media'/locale;target.mkdir(parents=True,exist_ok=True)
        for asset in manifest['assets']:
            for kind in ['video','poster']:shutil.copy2(directory/asset[kind],target/asset[kind])
        (target/('demo-manifest.json' if locale=='en' else 'manifest.json')).write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
        content=output/'content'/locale;content.mkdir(parents=True,exist_ok=True)
        for name in ['CLI.md','CONFIGURATION.md']:
            source=ROOT/'docs'/name if locale=='en' else ROOT/'docs'/locale/name
            shutil.copy2(source,content/name)
    for path,text in generated.items():
        target=output/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_text(text+'\n')
    print(f'Built {len(generated)} pages, {len(locales)} languages: {output}')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--version')
    p.add_argument('--locales',nargs='+',choices=LOCALES,default=LOCALES)
    args=p.parse_args()
    version=args.version or re.search(r'let appVersion = "([^"]+)"',(ROOT/'Project.swift').read_text())[1]
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:[.-][A-Za-z0-9.-]+)?',version):p.error('invalid version')
    build(args.output.resolve(),version,args.locales)
