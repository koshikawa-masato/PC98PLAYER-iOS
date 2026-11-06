#!/usr/bin/env python3
"""docs/index.html で使う文字だけを含む DotGothic16 の WOFF2 を作る。

使い方:
  pip install fonttools brotli
  curl -LO https://raw.githubusercontent.com/google/fonts/main/ofl/dotgothic16/DotGothic16-Regular.ttf
  python3 tools/site/subset_font.py DotGothic16-Regular.ttf

ASCII・ひらがな・カタカナ・主な記号は常に含めます。本文を書き換えて新しい漢字を
見出しに使った場合は再実行してください（含まれない文字は代替フォントで表示されます）。
"""
import html
import re
import sys
from pathlib import Path

from fontTools import subset

root = Path(__file__).resolve().parents[2]
source = Path(sys.argv[1]) if len(sys.argv) > 1 else None
if source is None or not source.is_file():
    sys.exit(__doc__)

text = html.unescape(re.sub(r"<[^>]+>", " ", (root / "docs/index.html").read_text(encoding="utf-8")))
chars = set(text)
chars.update(chr(c) for c in range(0x20, 0x7F))           # ASCII
chars.update(chr(c) for c in range(0x3000, 0x3100))       # 記号・ひらがな・カタカナ
chars.update(chr(c) for c in range(0xFF01, 0xFF5F))       # 全角英数
chars.update("・ー―…→←↑↓▶■□◆◇○●")

out = root / "docs/assets/fonts/DotGothic16-subset.woff2"
out.parent.mkdir(parents=True, exist_ok=True)
options = subset.Options()
options.flavor = "woff2"
options.layout_features = ["*"]
font = subset.load_font(str(source), options)
subsetter = subset.Subsetter(options)
subsetter.populate(text="".join(sorted(chars)))
subsetter.subset(font)
subset.save_font(font, str(out), options)
print(f"{out.relative_to(root)}: {out.stat().st_size} bytes, {len(chars)} chars")
