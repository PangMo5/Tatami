#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
import os,re,sys,tempfile
from pathlib import Path
file=Path(os.environ['DEMO_CONFIG']);gap=int(sys.argv[1])
if not 4<=gap<=40:raise SystemExit('gap must be 4...40')
text=file.read_text();text,count=re.subn(r'(?m)^(\s*gapInner\s*=\s*)\d+\s*$',lambda m:m[1]+str(gap),text)
if count!=1:raise SystemExit('expected exactly one gapInner setting')
with tempfile.NamedTemporaryFile(mode='w',dir=file.parent,delete=False) as output:
 output.write(text);name=output.name
os.replace(name,file)
print('config.toml: gapInner =',gap)
print('Tatami picks up the change through its normal live reload.')
