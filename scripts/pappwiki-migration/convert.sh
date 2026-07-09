#!/usr/bin/env bash
set -euo pipefail

WORK_DIR="${WORK_DIR:-$HOME/pappwiki-migration-work}"
XML="$WORK_DIR/xml/pages.xml"
OUT="$WORK_DIR/converted"
REPORT="$WORK_DIR/conversion-report.txt"

if [ ! -f "$XML" ]; then
  echo "ERROR: $XML not found. Run export.sh first."
  exit 1
fi

command -v pandoc >/dev/null 2>&1 || { echo "ERROR: pandoc not found in PATH"; exit 1; }

mkdir -p "$OUT"
: > "$REPORT"

python3 - "$XML" "$OUT" "$REPORT" << 'PYEOF'
import sys, re, os, subprocess, xml.etree.ElementTree as ET
import importlib.util, pathlib

# Load normalize.py from the same directory as this script
_script_dir = pathlib.Path(os.environ.get('BASH_SOURCE_DIR', os.getcwd()))
_normalize_candidates = [
    pathlib.Path(__file__).parent / "normalize.py" if '__file__' in dir() else None,
    _script_dir / "normalize.py",
    pathlib.Path(sys.argv[0]).parent / "normalize.py",
]
_normalize_path_file = None
for _c in _normalize_candidates:
    if _c and _c.exists():
        _normalize_path_file = _c
        break
if _normalize_path_file is None:
    # Last resort: search upward from cwd
    for _d in [pathlib.Path.cwd()] + list(pathlib.Path.cwd().parents):
        _candidate = _d / "scripts" / "pappwiki-migration" / "normalize.py"
        if _candidate.exists():
            _normalize_path_file = _candidate
            break
if _normalize_path_file is None:
    print("ERROR: cannot find normalize.py", file=sys.stderr)
    sys.exit(1)

spec = importlib.util.spec_from_file_location("normalize", _normalize_path_file)
normalize_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(normalize_mod)
normalize_path = normalize_mod.normalize_path
normalize_asset_name = normalize_mod.normalize_asset_name

xml_path, out_dir, report_path = sys.argv[1], sys.argv[2], sys.argv[3]

NS = '{http://www.mediawiki.org/xml/export-0.11/}'

tree = ET.parse(xml_path)
root = tree.getroot()

pages = root.findall(f'{NS}page')
ok = failed = 0

with open(report_path, 'w') as rpt:
    for page in pages:
        title_el = page.find(f'{NS}title')
        title = title_el.text if title_el is not None else 'Untitled'
        rev = page.find(f'.//{NS}text')
        wikitext = (rev.text or '') if rev is not None else ''

        path = normalize_path(title)
        out_file = os.path.join(out_dir, f"{path}.md")
        out_parent = os.path.dirname(out_file)
        if out_parent:
            os.makedirs(out_parent, exist_ok=True)

        # Extract categories → tags
        categories = re.findall(r'\[\[Category:([^\]]+)\]\]', wikitext, re.IGNORECASE)
        wikitext_no_cats = re.sub(r'\[\[Category:[^\]]+\]\]\n?', '', wikitext, flags=re.IGNORECASE)

        # Run pandoc
        result = subprocess.run(
            ['pandoc', '-f', 'mediawiki', '-t', 'gfm', '--wrap=none'],
            input=wikitext_no_cats.encode(),
            capture_output=True
        )

        if result.returncode == 0:
            md = result.stdout.decode()

            # Rewrite image refs to /images/<normalized-name>
            def replace_image(m):
                fname = m.group(1)
                return f"![{fname}](/images/{normalize_asset_name(fname)})"

            md = re.sub(r'!\[[^\]]*\]\((?:[^)]*/)?(.*?)\)', replace_image, md)
            md = re.sub(r'\[File:([^\]]+)\]\([^)]+\)', replace_image, md)

            # Prepend YAML front-matter
            tags_yaml = '\n'.join(f'  - {c.strip()}' for c in categories)
            tags_block = f"tags:\n{tags_yaml}\n" if categories else ""
            safe_title = title.replace('"', "'")
            header = f'---\ntitle: "{safe_title}"\n{tags_block}---\n\n'

            with open(out_file, 'w') as f:
                f.write(header + md)
            ok += 1
        else:
            # Fallback: raw wikitext in fenced code block — nothing silently dropped
            rpt.write(f"FAILED: {title} | pandoc stderr: {result.stderr.decode().strip()[:200]}\n")
            safe_title = title.replace('"', "'")
            with open(out_file, 'w') as f:
                f.write(f'---\ntitle: "{safe_title}"\n---\n\n')
                f.write('<!-- Conversion failed; raw wikitext preserved -->\n')
                f.write(f'```mediawiki\n{wikitext}\n```\n')
            failed += 1

print(f"Conversion complete: {ok} OK, {failed} failed (see {report_path})")
PYEOF
