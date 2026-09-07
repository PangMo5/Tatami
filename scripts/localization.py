# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Build-time text units. Code, links and markup remain structural data."""
from dataclasses import dataclass, field
from html.parser import HTMLParser
from pathlib import Path
import hashlib
import html
import json
import re

ROOT = Path(__file__).resolve().parents[1]
LOCALES = ['en', 'ko', 'ja', 'zh-Hans', 'zh-Hant']
NAMES = dict(zip(LOCALES, ['English', '한국어', '日本語', '简体中文', '繁體中文']))
IDENTITY = {'Tatami','GitHub','CLI','TOML','BSP','JSON','PangMo5','SwiftyCrow','Amado','macOS',
            'UUID','UUID[]','UUID[]?','double?','table?','string[]?','bool','string','string[]','string?','int','double','table','table[]',
            'en','ko','ja','zh-Hans','zh-Hant','true','false','null','Bool','String','Int','Float'}


def key(text):
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def human(text):
    if re.fullmatch(r'\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]', text): return False
    remainder = re.sub(r'\{\d+\}', '', text).strip()
    return bool(re.search('[A-Za-z]', remainder)) and remainder not in IDENTITY


@dataclass
class TextCatalog:
    values: dict = field(default_factory=dict)
    observed: dict = field(default_factory=dict)
    locale: str = 'en'

    def text(self, text, context):
        normalized = re.sub(r'\s+', ' ', text).strip()
        if not normalized or not human(normalized): return text
        identifier = key(normalized)
        self.observed.setdefault(identifier, {'en': normalized, 'context': context})
        if self.locale == 'en': return normalized
        value = self.values.get(identifier, {}).get(self.locale)
        if not value: raise ValueError(f'Missing {self.locale}: {identifier} / {normalized}')
        if sorted(re.findall(r'\{\d+\}', normalized)) != sorted(re.findall(r'\{\d+\}', value)):
            raise ValueError(f'Changed placeholders: {identifier} / {self.locale}')
        return value


VOID = {'area','base','br','col','embed','hr','img','input','link','meta','param','source','track','wbr'}
BLOCK = {'div','section','nav','aside','article','main','footer','header','ul','ol','li','video','pre'}
TRANSLATABLE = {'p','h1','h2','h3','h4','title','a','button','summary','label','span','option','sub','small'}

@dataclass
class Node:
    tag: str
    attrs: dict = field(default_factory=dict)
    children: list = field(default_factory=list)

    def render(self):
        if self.tag == '#root': return ''.join(render(c) for c in self.children)
        if self.tag == '#markup': return self.children[0]
        if self.tag == '#comment': return '<!--'+self.children[0]+'-->'
        if self.tag == '#doctype': return '<!'+self.children[0]+'>'
        attrs = ''.join(' '+k+(f'="{html.escape(v,quote=True)}"' if v is not None else '') for k,v in self.attrs.items())
        opening = '<'+self.tag+attrs+'>'
        if self.tag in VOID: return opening
        content = ''.join(self.children) if self.tag in {'script','style'} else ''.join(render(c) for c in self.children)
        return opening+content+'</'+self.tag+'>'


def render(value): return value.render() if isinstance(value,Node) else html.escape(value,quote=False)

class Document(HTMLParser):
    def __init__(self, source):
        super().__init__(convert_charrefs=True)
        self.root=Node('#root');self.stack=[self.root];self.feed(source)
    def handle_starttag(self, tag, attrs):
        node=Node(tag,dict(attrs));self.stack[-1].children.append(node)
        if tag not in VOID:self.stack.append(node)
    def handle_startendtag(self, tag, attrs): self.handle_starttag(tag,attrs)
    def handle_endtag(self, tag):
        if len(self.stack)>1 and self.stack[-1].tag==tag:self.stack.pop()
        elif tag not in VOID:raise ValueError(f'Mismatched closing tag: {tag}')
    def handle_data(self, data): self.stack[-1].children.append(data)
    def handle_comment(self, data):self.stack[-1].children.append(Node('#comment',children=[data]))
    def handle_decl(self, decl):self.stack[-1].children.append(Node('#doctype',children=[decl]))


def translate_html(source, catalog, context):
    document=Document(source)
    def visit(node):
        if node.tag in {'script','style','pre','#comment','#doctype'}:return
        for attribute in ['aria-label','title','alt','placeholder','data-play-hint','data-copied-label','data-copy-error','data-load-error','data-no-notes']:
            if node.attrs.get(attribute):node.attrs[attribute]=catalog.text(node.attrs[attribute],context+' / '+attribute)
        if node.tag=='meta' and node.attrs.get('name')=='description':node.attrs['content']=catalog.text(node.attrs['content'],context+' / meta')
        for child in node.children:
            if isinstance(child,Node):visit(child)
        eligible = node.tag in TRANSLATABLE or (node.tag=='div' and all(isinstance(c,str) for c in node.children))
        if not eligible or any(isinstance(c,Node) and c.tag in BLOCK for c in node.children):return
        protected=[];text=''
        for child in node.children:
            if isinstance(child,Node) and child.tag in {'em','strong','b','i'} and all(isinstance(c,str) for c in child.children):
                text+='{'+str(len(protected))+'}'+''.join(child.children);protected.append(Node('#markup',children=['<'+child.tag+'>']))
                text+='{'+str(len(protected))+'}';protected.append(Node('#markup',children=['</'+child.tag+'>']))
            elif isinstance(child,Node):
                text+='{'+str(len(protected))+'}';protected.append(child)
            else:text+=child
        localized=catalog.text(text,context+' / '+node.tag)
        children=[]
        for token in re.split(r'(\{\d+\})',localized):
            if re.fullmatch(r'\{\d+\}',token):children.append(protected[int(token[1:-1])])
            elif token:children.append(token)
        node.children=children
    visit(document.root)
    return document.root


# Inline source code and link destinations are opaque to the prose catalog.
INLINE=re.compile(r'<[^>]+>|(`+)(.+?)\1|(?<=\]\()([^\s)]+)(?=\))|https?://[^\s<>]+')

def inline_unit(text, catalog, context):
    protected=[]
    def protect(match):
        protected.append(match.group(0));return '{'+str(len(protected)-1)+'}'
    source=INLINE.sub(protect,text)
    localized=catalog.text(source,context)
    return re.sub(r'\{(\d+)\}',lambda m:protected[int(m.group(1))],localized)


def markdown_units(source, catalog, context):
    lines=source.splitlines();result=[];index=0;fence=None;reference_matrix=False
    while index<len(lines):
        line=lines[index]
        if not line.strip(): reference_matrix=False
        if context.endswith('LOCALIZATION.md') and line.startswith('| Concept |'): reference_matrix=True
        marker=re.match(r'^\s*(`{3,}|~{3,})',line)
        if marker:
            if fence is None:fence=marker.group(1)[0]
            elif marker.group(1)[0]==fence:fence=None
            result.append(line);index+=1;continue
        if fence or not line.strip() or line.startswith('<!--') or re.match(r'^\[[^]]+\]:',line):
            result.append(line);index+=1;continue
        if re.fullmatch(r'\s*</?details(?:\s[^>]*)?>\s*', line):
            result.append(line);index+=1;continue
        if line.lstrip().startswith('<'):
            # HTML blocks (README screenshots/disclosures) use the same DOM rules.
            block=[line];index+=1
            if re.match(r'^<(p|div)\b',line.strip()):
                while index<len(lines) and not re.search(r'</(?:p|div)>',block[-1]):block.append(lines[index]);index+=1
            try:result.append(translate_html('\n'.join(block),catalog,context+' / HTML').render())
            except ValueError:
                # Opening/closing disclosure tags carry no prose and span MD blocks.
                if all(re.fullmatch(r'\s*</?details>\s*',x) for x in block):result.extend(block)
                else:raise
            continue
        if line.startswith('> '):
            text=line[2:];index+=1
            if re.fullmatch(r'\[![A-Z]+\]',text):result.append(line);continue
            pieces=[text]
            while index<len(lines) and lines[index].startswith('> ') and lines[index][2:].strip():
                pieces.append(lines[index][2:]);index+=1
            result.append('> '+inline_unit(' '.join(pieces),catalog,context+' / quote'));continue
        heading=re.match(r'^(#{1,6})\s+(.+)$',line)
        if heading:
            result.append(heading.group(1)+' '+inline_unit(heading.group(2),catalog,context+' / heading'));index+=1;continue
        if line.startswith('|'):
            if re.fullmatch(r'[| :\-]+',line):result.append(line)
            else:
                # Pipes inside inline code belong to the sample, not the table.
                cells=re.split(r'\|(?=(?:[^`]*`[^`]*`)*[^`]*$)',line)
                def table_cell(i, cell):
                    text=cell.strip()
                    if reference_matrix and i>=2: return text
                    if context=='DemoLab/README.md':
                        if i==1 and text in {'Design','Write','Review','Chat','Build','Focus'}: return text
                        if i==2 and all(x.strip() in {'Canvas','Docs','Editor','Review','Chat','Terminal','Notes','Monitor'} for x in text.split('+')): return text
                    return inline_unit(text,catalog,context+' / table') if text else ''
                result.append('|'.join(table_cell(i,c) for i,c in enumerate(cells)))
            index+=1;continue
        prefix=re.match(r'^(\s*(?:[-*+] |\d+\. )|> )(.*)$',line)
        lead=prefix.group(1) if prefix else '';block=[prefix.group(2) if prefix else line];index+=1
        while index<len(lines) and lines[index].strip() and not re.match(r'^(?:#{1,6} |\s*[-*+] |\s*\d+\. |\||<|>|```|~~~)',lines[index]):
            block.append(lines[index].strip());index+=1
        result.append(lead+inline_unit(' '.join(block),catalog,context+' / prose'))
    return '\n'.join(result)+'\n'
