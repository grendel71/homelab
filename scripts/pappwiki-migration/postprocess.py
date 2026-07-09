#!/usr/bin/env python3
"""
Post-process converted Markdown files to fix MediaWiki conversion artefacts.

Fixes applied:
  1. Titles: underscore → space in YAML front-matter title
  2. \n literal strings → actual newlines (pandoc GFM output artifact)
  3. \* → * (escaped list bullets)
  4. Wikilinks: <a href="..." class="wikilink" title="...">text</a> → [text](normalized-path)
  5. Gallery blocks: lines matching File:...\|alt= → proper Markdown images
  6. Broken image captions leaking into paths: ![alt "cap"](/images/name-"cap".) → ![cap](/images/name.ext)
  7. Raw <img src="..."> tags → Markdown images using normalized asset names
  8. Infobox/template remnants: {{...}} blocks → stripped
  9. = Heading = style (single =) that pandoc left as-is → # Heading
  10. <categorytree> tags → stripped
  11. Trailing whitespace and excessive blank lines cleaned up
"""

import re, sys, pathlib, urllib.parse

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from normalize import normalize_path, normalize_asset_name


def fix_title(title: str) -> str:
    """Underscore to space in title."""
    return title.replace('_', ' ')


def fix_literal_newlines(text: str) -> str:
    r"""Replace literal \n sequences with real newlines."""
    return text.replace('\\n', '\n')


def fix_escaped_bullets(text: str) -> str:
    r"""Replace \* with * (pandoc over-escapes list markers sometimes).
    Also fix *\* (nested bullet) → indent with two spaces: "  *"
    """
    # Nested bullets: *\* → "  *"
    text = re.sub(r'^\*\\\*', '  *', text, flags=re.MULTILINE)
    # Leading escaped bullet: \* → *
    text = re.sub(r'^\\\*', '*', text, flags=re.MULTILINE)
    return text


def fix_wikilinks(text: str) -> str:
    """
    Convert <a href="Target_Page" class="wikilink" title="display">display text</a>
    to [display text](/normalized-path)
    """
    def replace_wikilink(m):
        href = m.group(1)
        link_text = m.group(2)
        # Normalize the href to a Wiki.js path
        # href may be "Page_Name" or "Page_Name#Section"
        anchor = ''
        if '#' in href:
            href, anchor = href.split('#', 1)
            anchor = '#' + anchor.lower().replace(' ', '-')
        path = normalize_path(urllib.parse.unquote(href))
        return f'[{link_text}](/{path}{anchor})'

    pattern = r'<a\s[^>]*class="wikilink"[^>]*href="([^"]+)"[^>]*>(.*?)</a>|<a\s+href="([^"]+)"\s+class="wikilink"[^>]*>(.*?)</a>'

    def smart_wikilink(m):
        href = m.group(1) or m.group(3)
        link_text = m.group(2) or m.group(4)
        anchor = ''
        if '#' in href:
            href, anchor = href.split('#', 1)
            anchor = '#' + anchor.lower().replace(' ', '-')
        path = normalize_path(urllib.parse.unquote(href))
        return f'[{link_text}](/{path}{anchor})'

    return re.sub(pattern, smart_wikilink, text, flags=re.DOTALL)


def fix_gallery_blocks(text: str) -> str:
    """
    Convert gallery remnants:
      File:Foo.png\|alt=
      File:Foo.png\|caption text
    to proper Markdown images.
    Also handles lines inside <p> tags from pandoc that contain File: refs.
    """
    def replace_file_line(m):
        filename = m.group(1).strip()
        caption = (m.group(2) or '').strip().lstrip('|').strip()
        norm = normalize_asset_name(filename)
        if caption and caption != 'alt=' and not caption.startswith('alt='):
            return f'![{caption}](/images/{norm})'
        else:
            return f'![{filename}](/images/{norm})'

    # Match: File:Filename.ext\|whatever  (with literal backslash-pipe or just pipe)
    text = re.sub(
        r'File:([^\\\n\|]+?)(?:\\?\|([^\n]*))?(?=\n|$)',
        replace_file_line,
        text
    )
    return text


def fix_broken_image_paths(text: str) -> str:
    """
    Fix pandoc image links where caption leaked into filename:
    ![Foo.png "The caption"](/images/foo.png-"the-caption".)
    → ![The caption](/images/foo.png)

    Also fix: ![Foo.png](/images/foo.png) → use just the normalized filename
    """
    def replace_broken_img(m):
        alt = m.group(1).strip()
        path = m.group(2).strip()

        # Extract just the filename before any -" or ."
        # e.g. /images/tierlist.png-"this-would-become-ironic." → tierlist.png
        clean_path = re.sub(r'["\-].*$', '', path)
        # Remove trailing dot
        clean_path = clean_path.rstrip('.')

        # If alt looks like "Filename.ext", use it as the image name instead
        if re.match(r'.+\.(png|jpg|jpeg|gif|svg|webp)', alt, re.IGNORECASE):
            # alt is the raw filename, path should be the normalized version
            # Just use clean_path which is /images/<name>
            return f'![{alt}]({clean_path})'
        else:
            # alt is a caption
            return f'![{alt}]({clean_path})'

    # Match markdown images with potentially corrupted paths
    return re.sub(r'!\[([^\]]*)\]\((/images/[^)]+)\)', replace_broken_img, text)


def fix_raw_img_tags(text: str) -> str:
    """
    Convert <img src="Foo.png" title="caption" ...> to ![caption](/images/foo.png)
    """
    def replace_img(m):
        src = m.group(1)
        title = m.group(2) or m.group(3) or src
        norm = normalize_asset_name(src)
        return f'![{title}](/images/{norm})'

    # <img src="..." title="..." .../>  or <img src="..." alt="..." .../>
    pattern = r'<img\s+src="([^"]+)"(?:[^>]*?title="([^"]*)")?(?:[^>]*?alt="([^"]*)")?[^>]*/?>'\
              r'|<img\s+src="([^"]+)"[^>]*/?>'\
              r'|<img[^>]+src="([^"]+)"[^>]*/?>'
    
    def smart_replace(m):
        full = m.group(0)
        src_m = re.search(r'src="([^"]+)"', full)
        title_m = re.search(r'title="([^"]*)"', full)
        alt_m = re.search(r'alt="([^"]*)"', full)
        if not src_m:
            return full
        src = src_m.group(1)
        caption = (title_m and title_m.group(1)) or (alt_m and alt_m.group(1)) or src
        # Skip if caption is same as src (uninformative)
        if caption == src:
            caption = ''
        norm = normalize_asset_name(src)
        return f'![{caption}](/images/{norm})'

    return re.sub(r'<img\b[^>]*/?>|<img\b[^>]*>', smart_replace, text)


def fix_infoboxes(text: str) -> str:
    """Strip {{Template ...}} blocks — infoboxes don't translate to Markdown."""
    # Multi-line {{...}} blocks
    text = re.sub(r'\{\{[^{}]*(?:\{\{[^{}]*\}\}[^{}]*)?\}\}', '', text, flags=re.DOTALL)
    # Any remaining single-line {{ }} 
    text = re.sub(r'\{\{[^\n]*\}\}', '', text)
    return text


def fix_single_eq_headings(text: str) -> str:
    """
    MediaWiki = Heading = (H1) that pandoc sometimes leaves as-is.
    Convert lines that are literally: = Some Text = → # Some Text
    """
    def replace_heading(m):
        level = len(m.group(1))
        content = m.group(2).strip()
        return '#' * level + ' ' + content
    # Match lines: =+ text =+  (equal sign headings pandoc didn't convert)
    return re.sub(r'^(=+)\s+(.+?)\s+=+\s*$', replace_heading, text, flags=re.MULTILINE)


def fix_categorytree(text: str) -> str:
    """Strip <categorytree ...>...</categorytree> tags."""
    text = re.sub(r'<categorytree[^>]*>.*?</categorytree>', '', text, flags=re.DOTALL | re.IGNORECASE)
    text = re.sub(r'<categorytree[^>]*/>', '', text, flags=re.IGNORECASE)
    return text


def fix_html_tables(text: str) -> str:
    """
    MediaWiki HTML tables used for layout (not data) — strip outer div/table wrappers.
    Keep the text content inside <td>/<th> cells, strip the tags.
    """
    # Strip layout divs 
    text = re.sub(r'<div[^>]*overflow-x:auto[^>]*>', '', text, flags=re.IGNORECASE)
    text = re.sub(r'<div[^>]*max-width[^>]*>', '', text, flags=re.IGNORECASE)
    text = re.sub(r'</?div[^>]*>', '', text)
    # Strip table structure tags but keep cell content
    text = re.sub(r'<table[^>]*>', '', text, flags=re.IGNORECASE)
    text = re.sub(r'</table>', '', text, flags=re.IGNORECASE)
    text = re.sub(r'<tr[^>]*>', '', text, flags=re.IGNORECASE)
    text = re.sub(r'</tr>', '', text, flags=re.IGNORECASE)
    text = re.sub(r'<td[^>]*>', '', text, flags=re.IGNORECASE)
    text = re.sub(r'</td>', '', text, flags=re.IGNORECASE)
    text = re.sub(r'<th[^>]*>', '**', text, flags=re.IGNORECASE)
    text = re.sub(r'</th>', '**', text, flags=re.IGNORECASE)
    return text


def fix_paragraph_tags(text: str) -> str:
    """Strip remaining <p>, </p>, <font>, </font>, <u>, </u>, <b>, </b> tags."""
    text = re.sub(r'</?p[^>]*>', '', text, flags=re.IGNORECASE)
    text = re.sub(r'<font[^>]*>', '', text, flags=re.IGNORECASE)
    text = re.sub(r'</font>', '', text, flags=re.IGNORECASE)
    text = re.sub(r'</?u>', '', text, flags=re.IGNORECASE)
    text = re.sub(r'</?b>', '', text, flags=re.IGNORECASE)
    text = re.sub(r'</?blockquote[^>]*>', '', text, flags=re.IGNORECASE)
    return text


def fix_excess_blank_lines(text: str) -> str:
    """Collapse 3+ consecutive blank lines to 2."""
    return re.sub(r'\n{3,}', '\n\n', text)


def fix_frontmatter_title(text: str) -> str:
    """Fix underscore-spaced titles in YAML front-matter."""
    def replace_title(m):
        raw = m.group(1)
        fixed = fix_title(raw)
        return f'title: "{fixed}"'
    return re.sub(r'^title:\s*"([^"]+)"', replace_title, text, flags=re.MULTILINE)


def postprocess(content: str) -> str:
    """Apply all fixes in order."""
    content = fix_frontmatter_title(content)
    content = fix_literal_newlines(content)
    content = fix_single_eq_headings(content)
    content = fix_infoboxes(content)
    content = fix_categorytree(content)
    content = fix_gallery_blocks(content)
    content = fix_raw_img_tags(content)
    content = fix_broken_image_paths(content)
    content = fix_wikilinks(content)
    content = fix_html_tables(content)
    content = fix_paragraph_tags(content)
    content = fix_escaped_bullets(content)
    content = fix_excess_blank_lines(content)
    return content.strip() + '\n'


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <converted-dir>")
        sys.exit(1)

    converted_dir = pathlib.Path(sys.argv[1])
    md_files = sorted(converted_dir.glob('*.md'))
    print(f"Post-processing {len(md_files)} files in {converted_dir}")

    for md_file in md_files:
        original = md_file.read_text(encoding='utf-8')
        fixed = postprocess(original)
        if fixed != original:
            md_file.write_text(fixed, encoding='utf-8')
            print(f"  fixed: {md_file.name}")
        else:
            print(f"  ok:    {md_file.name}")

    print("Done.")
