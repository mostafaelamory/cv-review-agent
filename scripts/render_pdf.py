"""Renders a Markdown file (with Mermaid diagrams) to PDF using headless Google Chrome.

Usage:
  python3 scripts/render_pdf.py <input.md> <output.pdf> [title]
  python3 scripts/render_pdf.py <input.md> <output.pdf> --professional \
      --subtitle "..." --doc-type "Technical README" --date "November 2026"

The professional style adds a cover page, a contents page, numbered sections,
a running header and page numbers. Loads marked, mermaid and fonts from public
CDNs at render time, so it needs network access.
"""
import argparse
import html
import json
import os
import subprocess
import tempfile

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

PLAIN_CSS = """
  @page { size: A4; margin: 16mm 14mm 18mm 14mm; }
  body { font-family: -apple-system, "Segoe UI", Helvetica, Arial, sans-serif; font-size: 10pt;
         line-height: 1.45; color: #1f2328; }
  h1 { font-size: 20pt; margin: 0 0 6pt; border-bottom: 2px solid #1f2328; padding-bottom: 4pt; }
  h2 { font-size: 14pt; margin: 18pt 0 6pt; border-bottom: 1px solid #d0d7de; padding-bottom: 3pt;
       page-break-after: avoid; }
  h3 { font-size: 11.5pt; margin: 12pt 0 4pt; page-break-after: avoid; }
  p, li { orphans: 3; widows: 3; }
  table { border-collapse: collapse; width: 100%; margin: 6pt 0 10pt; font-size: 8.6pt; }
  tr { page-break-inside: avoid; }
  th, td { border: 1px solid #d0d7de; padding: 4pt 5pt; vertical-align: top; text-align: left; }
  th { background: #f3f4f6; }
  code { font-family: Menlo, Consolas, monospace; font-size: 8.4pt; background: #f3f4f6; padding: 0 2pt;
         border-radius: 3px; }
  pre { background: #f6f8fa; border: 1px solid #d0d7de; border-radius: 4px; padding: 6pt;
        white-space: pre-wrap; word-break: break-word; page-break-inside: avoid; }
  pre code { background: none; padding: 0; }
  blockquote { margin: 6pt 0; padding: 4pt 10pt; border-left: 3px solid #8c959f; color: #3b434b;
               background: #f6f8fa; }
  a { color: #0b5cab; text-decoration: none; }
  hr { border: none; border-top: 1px solid #d0d7de; margin: 12pt 0; }
  .mermaid { text-align: center; margin: 8pt 0; page-break-inside: avoid; }
  .mermaid svg { max-width: 100%; height: auto; }
  ul.contains-task-list { list-style: none; padding-left: 12pt; }
  input[type=checkbox] { margin-right: 4pt; }
"""

PRO_CSS = """
  :root { --ink: #1f2328; --muted: #6b6f76; --head: #1a1d21; --accent: #2f6b4f; --line: #e2e1dc;
          --soft: #f7f6f3; }
  @page {
    size: A4; margin: 24mm 20mm 20mm 20mm;
    @top-left { content: "__RUNNING__"; font: 400 7.5pt Inter, sans-serif; color: #8a8d92;
                vertical-align: bottom; padding-bottom: 4mm; }
    @top-right { content: "__DOCTYPE__"; font: 400 7.5pt Inter, sans-serif; color: #8a8d92;
                 vertical-align: bottom; padding-bottom: 4mm; }
    @bottom-right { content: counter(page) " / " counter(pages); font: 400 7.5pt Inter, sans-serif;
                    color: #8a8d92; }
  }
  @page cover { margin: 0; @top-left { content: none; } @top-right { content: none; }
                @bottom-right { content: none; } }
  body { font-family: Inter, -apple-system, "Segoe UI", Helvetica, Arial, sans-serif; font-size: 9.6pt;
         line-height: 1.6; color: var(--ink); margin: 0; }

  /* Cover: quiet, white, typographic */
  .cover { page: cover; height: 297mm; position: relative; break-after: page; overflow: hidden;
           padding: 0 24mm; box-sizing: border-box; }
  .cover .band { padding-top: 70mm; }
  .cover .eyebrow { font-size: 8.5pt; letter-spacing: .14em; text-transform: uppercase; color: var(--accent);
                    font-weight: 600; }
  .cover h1 { font-family: "Source Serif 4", Georgia, serif; font-size: 34pt; line-height: 1.12;
              margin: 6mm 0 6mm; font-weight: 600; color: var(--head); border: none; }
  .cover .subtitle { font-size: 12.5pt; color: var(--muted); max-width: 150mm; line-height: 1.5; }
  .cover .rule { height: 1px; width: 100%; background: var(--line); margin-top: 14mm; }
  .cover .abstract { padding-top: 8mm; font-size: 10.5pt; color: var(--ink); max-width: 150mm; }
  .cover .repo { padding-top: 7mm; font-size: 10pt; }
  .cover .repo span { display: block; font-size: 7.5pt; letter-spacing: .12em; text-transform: uppercase;
                      color: var(--muted); margin-bottom: 1.5mm; }
  .cover .repo a { color: var(--accent); font-weight: 500; }
  .cover .meta { position: absolute; left: 24mm; right: 24mm; bottom: 24mm; border-top: 1px solid var(--line);
                 padding-top: 6mm; display: grid; grid-template-columns: repeat(3, 1fr); gap: 6mm; }
  .cover .meta div span { display: block; font-size: 7.5pt; letter-spacing: .12em; text-transform: uppercase;
                          color: var(--muted); margin-bottom: 1.5mm; }
  .cover .meta div b { font-size: 9.5pt; font-weight: 500; color: var(--head); }

  /* Contents */
  .toc { break-after: page; }
  .toc h2.toc-title { font-family: "Source Serif 4", Georgia, serif; font-size: 20pt; font-weight: 600;
                      color: var(--head); margin: 0 0 8mm; border: none; padding: 0; }
  .toc h2.toc-title::before { content: none; }
  .toc ol { list-style: none; padding: 0; margin: 0; counter-reset: toc; }
  .toc li { counter-increment: toc; display: flex; gap: 6mm; padding: 3.2mm 0; border-bottom: 1px solid var(--line);
            font-size: 11pt; color: var(--head); }
  .toc li::before { content: counter(toc, decimal-leading-zero); color: var(--accent); font-weight: 600;
                    min-width: 9mm; }

  /* Body */
  #content { counter-reset: h2; }
  #content h1 { display: none; }
  h2 { counter-increment: h2; font-family: "Source Serif 4", Georgia, serif; font-size: 16pt; font-weight: 600;
       color: var(--head); margin: 10mm 0 3.5mm; padding-bottom: 2mm; border-bottom: 1px solid var(--line);
       break-after: avoid; }
  h2::before { content: counter(h2) "."; color: var(--accent); margin-right: 3mm; }
  h2.newpage { break-before: page; margin-top: 0; }
  h3 { font-size: 10.5pt; color: var(--head); margin: 6mm 0 2mm; break-after: avoid; font-weight: 600; }
  p { margin: 0 0 2.6mm; orphans: 3; widows: 3; }
  ul, ol { margin: 0 0 3mm; padding-left: 6mm; }
  li { margin: .8mm 0; }
  li::marker { color: #8a8d92; }
  strong { color: var(--head); font-weight: 600; }
  hr { display: none; }
  a { color: var(--accent); text-decoration: none; }
  table { border-collapse: collapse; width: 100%; margin: 3mm 0 5mm; font-size: 8.6pt; }
  thead th { background: var(--soft); color: var(--head); font-weight: 600; text-align: left; padding: 2.2mm 2.6mm;
             border-top: 1.5px solid var(--head); border-bottom: 1px solid var(--head); }
  td { padding: 2mm 2.6mm; vertical-align: top; border-bottom: 1px solid var(--line); }
  tr { break-inside: avoid; }
  code { font-family: "JetBrains Mono", Menlo, monospace; font-size: 8pt; background: #f1f0ec; padding: .3mm 1.2mm;
         border-radius: 2px; color: #33373c; }
  pre { background: var(--soft); color: var(--ink); border: 1px solid var(--line); border-radius: 2px; padding: 4mm;
        white-space: pre-wrap; word-break: break-word; break-inside: avoid; font-size: 8pt; line-height: 1.55; }
  pre code { background: none; color: inherit; padding: 0; }
  blockquote { margin: 3mm 0 5mm; padding: 3.5mm 5mm; background: #f3f6f3; border-left: 3px solid var(--accent);
               color: var(--ink); }
  blockquote p:last-child { margin: 0; }
  .mermaid { text-align: center; margin: 3mm 0 5mm; break-inside: avoid; padding: 4mm; border: 1px solid var(--line);
             background: #fff; }
  .mermaid svg, .mermaid img { max-width: 100%; height: auto; }
"""

PRO_FONTS = ('<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700'
             '&family=Source+Serif+4:wght@600&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">')

TEMPLATE = """<!doctype html>
<html><head><meta charset="utf-8"><title>__TITLE__</title>__FONTS__
<style>__CSS__</style></head>
<body>__COVER__<div id="toc"></div><div id="content"></div>
<script src="https://cdn.jsdelivr.net/npm/marked@12.0.2/marked.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/mermaid@10.9.1/dist/mermaid.min.js"></script>
<script>
  const md = __MARKDOWN__;
  const professional = __PRO__;
  const renderer = new marked.Renderer();
  const baseCode = renderer.code.bind(renderer);
  renderer.code = (code, lang) => lang === 'mermaid'
      ? '<div class="mermaid">' + code.replace(/&/g,'&amp;').replace(/</g,'&lt;') + '</div>'
      : baseCode(code, lang);
  const content = document.getElementById('content');
  content.innerHTML = marked.parse(md, { renderer, gfm: true });

  if (professional) {
    // Contents page from the H2 headings.
    const items = [...content.querySelectorAll('h2')].map(h => '<li><div>' + h.textContent + '</div></li>');
    document.getElementById('toc').innerHTML =
      '<section class="toc"><h2 class="toc-title">Contents</h2><ol>' + items.join('') + '</ol></section>';
    // Sections that open with a diagram start on a new page, so the diagram is not split.
    content.querySelectorAll('h2').forEach(h => {
      const next = h.nextElementSibling;
      if (next && next.classList.contains('mermaid')) h.classList.add('newpage');
    });
  }

  mermaid.initialize({
    startOnLoad: false, securityLevel: 'loose',
    theme: professional ? 'base' : 'neutral',
    themeVariables: professional ? {
      fontFamily: 'Helvetica, Arial, sans-serif', fontSize: '13px', primaryColor: '#f7f6f3', primaryBorderColor: '#6b6f76',
      primaryTextColor: '#1f2328', lineColor: '#8a8d92', secondaryColor: '#f7f6f3', tertiaryColor: '#ffffff'
    } : {},
    flowchart: { htmlLabels: true, useMaxWidth: true }
  });
  const fontsReady = document.fonts ? document.fonts.ready : Promise.resolve();
  // Each rendered diagram becomes a self-contained image so diagrams on different pages cannot overlap in print.
  const toImages = () => document.querySelectorAll('.mermaid svg').forEach(svg => {
    const box = svg.getBoundingClientRect();
    const img = new Image();
    img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(new XMLSerializer().serializeToString(svg));
    img.style.width = Math.min(box.width, svg.parentElement.clientWidth) + 'px';
    img.style.maxWidth = '100%';
    svg.replaceWith(img);
  });
  // Render each diagram on its own with a unique id, so two diagrams never share a canvas.
  const renderAll = async () => {
    const blocks = [...document.querySelectorAll('.mermaid')];
    for (let i = 0; i < blocks.length; i++) {
      const { svg } = await mermaid.render('diagram' + i + '_' + Date.now(), blocks[i].textContent);
      blocks[i].innerHTML = svg;
    }
  };
  fontsReady.then(renderAll).then(toImages).then(() => { document.title = 'READY'; });
</script></body></html>
"""


def cover_html(title, subtitle, abstract, doc_type, date, platform, repo=""):
    def esc(s):
        return html.escape(s or "")
    return f"""<section class="cover">
  <div class="band">
    <div class="eyebrow">{esc(doc_type)}</div>
    <h1>{esc(title)}</h1>
    <div class="subtitle">{esc(subtitle)}</div>
    <div class="rule"></div>
  </div>
  <div class="abstract">{esc(abstract)}</div>
  {f'<div class="repo"><span>Source code</span><a href="{esc(repo)}">{esc(repo.replace("https://", ""))}</a></div>' if repo else ''}
  <div class="meta">
    <div><span>Document</span><b>{esc(doc_type)}</b></div>
    <div><span>Platform</span><b>{esc(platform)}</b></div>
    <div><span>Date</span><b>{esc(date)}</b></div>
  </div>
</section>"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("out")
    ap.add_argument("title", nargs="?")
    ap.add_argument("--professional", action="store_true")
    ap.add_argument("--subtitle", default="")
    ap.add_argument("--abstract", default="")
    ap.add_argument("--doc-type", default="Technical README")
    ap.add_argument("--date", default="")
    ap.add_argument("--platform", default="Salesforce")
    ap.add_argument("--repo", default="")
    args = ap.parse_args()

    with open(args.src, encoding="utf-8") as f:
        markdown = f.read()
    first_h1 = next((l[2:].strip() for l in markdown.splitlines() if l.startswith("# ")), "")
    title = args.title or first_h1 or os.path.basename(args.src)

    if args.professional:
        css = PRO_CSS.replace("__RUNNING__", title.replace('"', "")).replace("__DOCTYPE__", args.doc_type)
        cover = cover_html(title, args.subtitle, args.abstract, args.doc_type, args.date, args.platform, args.repo)
        fonts = PRO_FONTS
    else:
        css, cover, fonts = PLAIN_CSS, "", ""

    page = (TEMPLATE.replace("__TITLE__", html.escape(title)).replace("__CSS__", css).replace("__COVER__", cover)
            .replace("__FONTS__", fonts).replace("__PRO__", "true" if args.professional else "false")
            .replace("__MARKDOWN__", json.dumps(markdown)))
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "doc.html")
        with open(path, "w", encoding="utf-8") as f:
            f.write(page)
        subprocess.run(
            [CHROME, "--headless=new", "--disable-gpu", "--no-pdf-header-footer",
             "--virtual-time-budget=25000", "--run-all-compositor-stages-before-draw",
             f"--print-to-pdf={os.path.abspath(args.out)}", "file://" + path],
            check=True, capture_output=True,
        )
    print("wrote", args.out)


if __name__ == "__main__":
    main()
