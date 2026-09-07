# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
import importlib.util
import json
from pathlib import Path
import re
import unittest
from localization import ROOT, TextCatalog, key, inline_unit, markdown_units, translate_html

class LocalizationContracts(unittest.TestCase):
    def test_inline_code_and_link_destination_survive_reordered_prose(self):
        source='Run `tatami workspace list`, then read [the guide](CLI.md#json).'
        value='[안내]({1})를 읽고 {0}을 실행해요.'
        catalog=TextCatalog(values={key('Run {0}, then read [the guide]({1}).'):{'ko':value}},locale='ko')
        output=inline_unit(source,catalog,'test')
        self.assertEqual(output,'[안내](CLI.md#json)를 읽고 `tatami workspace list`을 실행해요.')

    def test_missing_or_changed_placeholders_fail(self):
        source='Use {0}.'
        with self.assertRaisesRegex(ValueError,'Missing'):
            TextCatalog(locale='ja').text(source,'test')
        with self.assertRaisesRegex(ValueError,'Changed placeholders'):
            TextCatalog(values={key(source):{'ja':'使ってください。'}},locale='ja').text(source,'test')

    def test_reference_matrix_preserves_other_languages(self):
        source='| Concept | `en` | `ko` |\n| --- | --- | --- |\n| Workspace | Workspace | 작업 공간 |\n'
        catalog=TextCatalog(values={key('Concept'):{'ko':'개념'},key('Workspace'):{'ko':'작업 공간'}},locale='ko')
        output=markdown_units(source,catalog,'docs/LOCALIZATION.md')
        self.assertIn('|작업 공간|Workspace|작업 공간|',output)

    def test_quote_is_one_sentence_and_admonition_is_syntax(self):
        source='> [!NOTE]\n> A window stays\n> where you put it.\n'
        catalog=TextCatalog(values={key('A window stays where you put it.'):{'ko':'창이 놓아둔 자리에 남아요.'}},locale='ko')
        self.assertEqual(markdown_units(source,catalog,'test'),'> [!NOTE]\n> 창이 놓아둔 자리에 남아요.\n')

    def test_emphasis_can_move_with_a_complete_sentence(self):
        catalog=TextCatalog(values={key('This <unused>'):{'ko':'unused'},key('The window {0}is{1} real.'):{'ko':'{0}실제 창{1}이에요.'}},locale='ko')
        self.assertEqual(translate_html('<p>The window <em>is</em> real.</p>',catalog,'test').render(),'<p><em>실제 창</em>이에요.</p>')

    def test_generated_documents_preserve_code_and_do_not_drift(self):
        spec=importlib.util.spec_from_file_location('build_docs',ROOT/'scripts/build-docs.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        values=json.loads((ROOT/'Localization/Docs.json').read_text())
        def fences(text):return re.findall(r'(?ms)^(`{3,}|~{3,})[^\n]*\n(.*?)^\1\s*$',text)
        for source in module.DOCUMENTS:
            original=module.NAV.sub('',(ROOT/source).read_text()).lstrip('\n')
            localized_source=(ROOT/'Localization/ThirdPartyNotice.md').read_text() if source.name=='THIRD_PARTY_NOTICES.md' else original
            for locale in module.LOCALES[1:]:
                text=markdown_units(localized_source,TextCatalog(values=values,locale=locale),str(source))
                text=module.anchor_headings(text,module.headings(localized_source))
                expected=module.language_links(source,locale)+module.rewrite_links(text,source,locale)
                actual=(ROOT/module.destination(source,locale)).read_text()
                self.assertEqual(actual,expected,f'{source} / {locale}')
                self.assertEqual(fences(localized_source),fences(actual),f'changed code: {source} / {locale}')

if __name__=='__main__':unittest.main()
