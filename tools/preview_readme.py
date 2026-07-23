#!/usr/bin/env python3
"""Render README.md to a single self-contained HTML file.

Every image, GIF and video is inlined as a data URI, so the result opens
anywhere with no server and no relative paths to get wrong. The MP4 is given a
real <video> element, which GitHub strips out of markdown but a browser will
play.

Usage:
    python3 tools/preview_readme.py [out.html]
"""
import base64
import mimetypes
import os
import re
import sys

import markdown

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

CSS = """
:root { color-scheme: light dark; }
* { box-sizing: border-box; }
body {
  margin: 0 auto; max-width: 900px; padding: 2.5rem 1.5rem 6rem;
  font: 16px/1.65 -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  color: #1f2328; background: #fff;
}
@media (prefers-color-scheme: dark) {
  body { color: #e6edf3; background: #0d1117; }
  a { color: #4493f8; }
  code, pre { background: #161b22 !important; }
  table th, table td { border-color: #30363d !important; }
  table th { background: #161b22 !important; }
  blockquote, em { color: #9198a1; }
  hr { border-color: #30363d; }
}
h1 { font-size: 2rem; padding-bottom: .3em; border-bottom: 1px solid #d1d9e0; }
h2 { font-size: 1.5rem; margin-top: 2.2rem; padding-bottom: .3em;
     border-bottom: 1px solid #d1d9e0; }
h3 { font-size: 1.2rem; margin-top: 1.8rem; }
@media (prefers-color-scheme: dark) { h1, h2 { border-color: #30363d; } }
img, video { max-width: 100%; border-radius: 6px; display: block;
             margin: 1.2rem auto; box-shadow: 0 1px 6px rgba(0,0,0,.25); }
pre { background: #f6f8fa; padding: 1rem; overflow-x: auto; border-radius: 6px;
      font-size: 13.5px; line-height: 1.45; }
code { background: #f6f8fa; padding: .15em .35em; border-radius: 4px;
       font-size: 85%; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
pre code { background: none; padding: 0; font-size: inherit; }
table { border-collapse: collapse; margin: 1rem 0; width: 100%; font-size: 14px; }
table th, table td { border: 1px solid #d1d9e0; padding: .5rem .75rem;
                     text-align: left; vertical-align: top; }
table th { background: #f6f8fa; font-weight: 600; }
em { color: #59636e; }
p em:only-child { display: block; text-align: center; font-size: 14px; }
.banner { background: #0b1020; color: #7ee787; border: 1px solid #30363d;
          padding: .35rem .6rem; border-radius: 4px; font-size: 12px;
          display: inline-block; margin-bottom: 1.5rem;
          font-family: ui-monospace, monospace; }
"""


def data_uri(path):
    mime = mimetypes.guess_type(path)[0] or "application/octet-stream"
    with open(path, "rb") as f:
        return "data:%s;base64,%s" % (mime, base64.b64encode(f.read()).decode())


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "README_preview.html"
    src = os.path.join(ROOT, "README.md")
    text = open(src, encoding="utf-8").read()

    inlined = []

    # markdown images -> data URIs
    def img_sub(m):
        alt, rel = m.group(1), m.group(2)
        p = os.path.join(ROOT, rel)
        if not os.path.exists(p):
            return m.group(0)
        inlined.append(rel)
        return "![%s](%s)" % (alt, data_uri(p))

    text = re.sub(r"!\[([^\]]*)\]\(([^)\s]+)\)", img_sub, text)

    # a link to a video becomes a player
    def vid_sub(m):
        rel = m.group(2)
        p = os.path.join(ROOT, rel.strip("`"))
        if not (rel.endswith(".mp4") and os.path.exists(p)):
            return m.group(0)
        inlined.append(rel)
        return ('<video controls loop muted playsinline src="%s"></video>'
                % data_uri(p))

    text = re.sub(r"\[([^\]]*)\]\(([^)\s]+\.mp4)\)", vid_sub, text)

    body = markdown.markdown(
        text, extensions=["tables", "fenced_code", "toc", "sane_lists"]
    )

    html = (
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
        "<title>blitsCRT_Mister</title><style>%s</style></head><body>"
        "<div class=\"banner\">local preview &mdash; media inlined, "
        "video playable</div>\n%s</body></html>" % (CSS, body)
    )

    with open(out, "w", encoding="utf-8") as f:
        f.write(html)

    size = os.path.getsize(out)
    print("wrote %s (%.1f MB)" % (out, size / 1e6))
    for rel in inlined:
        print("  inlined %s" % rel)


if __name__ == "__main__":
    main()
