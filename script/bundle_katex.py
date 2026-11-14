#!/usr/bin/env python3
"""Vendor an extracted official KaTeX npm package, embedding WOFF2 fonts in CSS.

Usage: python3 script/bundle_katex.py /path/to/extracted/package
No dependency downloads happen at build time or while the app is running.
"""
import base64
import pathlib
import re
import shutil
import sys

package = pathlib.Path(sys.argv[1])
resources = pathlib.Path(__file__).resolve().parents[1] / "Sources/SynologyNote/Resources"
css = (package / "dist/katex.min.css").read_text()


def embed_font(match):
    name = match.group(1)
    encoded = base64.b64encode((package / "dist/fonts" / name).read_bytes()).decode("ascii")
    return f'src:url(data:font/woff2;base64,{encoded}) format("woff2")'


css, count = re.subn(r'src:url\(fonts/([^)]*\.woff2)\) format\("woff2"\)[^;]*', embed_font, css)
assert count == 20, f"Expected 20 font faces, found {count}"
assert "url(fonts/" not in css
resources.mkdir(parents=True, exist_ok=True)
(resources / "katex-offline.min.css").write_text(css + "\n")
shutil.copyfile(package / "dist/katex.min.js", resources / "katex.min.js")
shutil.copyfile(package / "LICENSE", resources / "KATEX-LICENSE.txt")
print(f"Bundled KaTeX with {count} embedded WOFF2 fonts")
