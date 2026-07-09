#!/usr/bin/env python3
"""
Import converted pages and images into Wiki.js via GraphQL API.

Usage:
  python3 import.py --url https://papp.envoy.grendel71.net --token <api-key> \
                    --pages ~/pappwiki-migration-work/converted \
                    --images ~/pappwiki-migration-work/images

Idempotent: pages/assets that already exist are skipped.
"""
import argparse, os, sys, re, pathlib, requests, json, time

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from normalize import normalize_path, normalize_asset_name

# ---------------------------------------------------------------------------
# GraphQL helpers
# ---------------------------------------------------------------------------

def gql(url: str, token: str, query: str, variables: dict = None) -> dict:
    resp = requests.post(
        f"{url}/graphql",
        json={"query": query, "variables": variables or {}},
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        timeout=30,
    )
    resp.raise_for_status()
    body = resp.json()
    if "errors" in body:
        raise RuntimeError(f"GraphQL error: {body['errors']}")
    return body["data"]

LIST_PAGES_QUERY = """
query { pages { list { path } } }
"""

CREATE_PAGE_MUTATION = """
mutation CreatePage($content: String!, $description: String!, $editor: String!,
                    $isPublished: Boolean!, $locale: String!, $path: String!,
                    $tags: [String]!, $title: String!) {
  pages {
    create(content: $content, description: $description, editor: $editor,
           isPublished: $isPublished, locale: $locale, path: $path,
           tags: $tags, title: $title) {
      responseResult { succeeded errorCode message }
      page { id }
    }
  }
}
"""

# ---------------------------------------------------------------------------
# Asset upload
# ---------------------------------------------------------------------------

def upload_asset(url: str, token: str, filepath: pathlib.Path, folder_id: int) -> bool:
    """Upload a single file as a Wiki.js asset. Returns True on success."""
    with open(filepath, 'rb') as f:
        resp = requests.post(
            f"{url}/u",
            files={"mediaUpload": (filepath.name, f)},
            data={"mediaUpload": json.dumps({"folderId": folder_id})},
            headers={"Authorization": f"Bearer {token}"},
            timeout=60,
        )
    if resp.status_code == 200:
        return True
    print(f"  WARN: asset upload returned {resp.status_code} for {filepath.name}: {resp.text[:200]}")
    return False

LIST_ASSET_FOLDERS_QUERY = """
query { assets { folders(parentFolderId: 0) { id name } } }
"""

CREATE_ASSET_FOLDER_MUTATION = """
mutation { assets { createFolder(parentFolderId: 0, slug: "images", name: "images") {
  responseResult { succeeded errorCode message }
} } }
"""

def get_or_create_images_folder(url: str, token: str) -> int:
    data = gql(url, token, LIST_ASSET_FOLDERS_QUERY)
    for folder in data["assets"]["folders"]:
        if folder["name"] == "images":
            return folder["id"]
    gql(url, token, CREATE_ASSET_FOLDER_MUTATION)
    data = gql(url, token, LIST_ASSET_FOLDERS_QUERY)
    for folder in data["assets"]["folders"]:
        if folder["name"] == "images":
            return folder["id"]
    raise RuntimeError("Could not create or find 'images' asset folder")

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_frontmatter(text: str):
    """Return (title, tags, body) parsed from YAML front-matter."""
    title, tags, body = "Untitled", [], text
    if text.startswith("---"):
        end = text.find("\n---\n", 3)
        if end != -1:
            fm = text[3:end]
            body = text[end+5:]
            m = re.search(r'^title:\s*"?(.+?)"?\s*$', fm, re.MULTILINE)
            if m:
                title = m.group(1)
            tags = re.findall(r'^\s*-\s+(.+)$', fm, re.MULTILINE)
    return title, [t.strip() for t in tags], body.strip()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True, help="Wiki.js base URL (no trailing slash)")
    ap.add_argument("--token", required=True, help="Wiki.js API key")
    ap.add_argument("--pages", required=True, help="Directory of converted .md files")
    ap.add_argument("--images", required=True, help="Directory of extracted wiki images")
    ap.add_argument("--dry-run", action="store_true", help="Print actions without executing")
    args = ap.parse_args()

    url = args.url.rstrip("/")
    token = args.token
    pages_dir = pathlib.Path(args.pages)
    images_dir = pathlib.Path(args.images)

    # ------------------------------------------------------------------
    # Phase 1: assets
    # ------------------------------------------------------------------
    print("==> Phase 1: uploading image assets")
    folder_id = get_or_create_images_folder(url, token) if not args.dry_run else 0
    print(f"    images folder id: {folder_id}")

    image_files = [p for p in images_dir.rglob("*") if p.is_file()
                   and not p.name.startswith(".")
                   and p.suffix.lower() in {".png",".jpg",".jpeg",".gif",".svg",".webp",".tiff",".tif"}]
    print(f"    {len(image_files)} image files found")

    asset_ok = asset_skip = asset_fail = 0
    for img in sorted(image_files):
        new_name = normalize_asset_name(img.name)
        if args.dry_run:
            print(f"    [dry] would upload {img.name} → images/{new_name}")
            asset_ok += 1
            continue
        # Rename to normalised name in a temp location
        tmp = img.parent / new_name
        try:
            if not tmp.exists():
                img.rename(tmp)
            success = upload_asset(url, token, tmp, folder_id)
            if success:
                asset_ok += 1
            else:
                asset_fail += 1
        except Exception as e:
            print(f"  ERROR uploading {img.name}: {e}")
            asset_fail += 1
        time.sleep(0.05)   # gentle rate-limit

    print(f"    assets: {asset_ok} uploaded, {asset_fail} failed, {asset_skip} skipped")

    # ------------------------------------------------------------------
    # Phase 2: pages
    # ------------------------------------------------------------------
    print("==> Phase 2: creating pages")
    if not args.dry_run:
        existing = {p["path"] for p in gql(url, token, LIST_PAGES_QUERY)["pages"]["list"]}
    else:
        existing = set()

    md_files = sorted(pages_dir.rglob("*.md"))
    print(f"    {len(md_files)} Markdown files found")

    page_ok = page_skip = page_fail = 0
    for md in md_files:
        rel = md.relative_to(pages_dir)
        text = md.read_text()
        title, tags, body = parse_frontmatter(text)
        path = normalize_path(title)   # consistent with how convert.sh named the file

        if path in existing:
            page_skip += 1
            continue

        if args.dry_run:
            print(f"    [dry] would create /{path} — \"{title}\" tags={tags}")
            page_ok += 1
            continue

        try:
            data = gql(url, token, CREATE_PAGE_MUTATION, {
                "content": body,
                "description": "",
                "editor": "markdown",
                "isPublished": True,
                "locale": "en",
                "path": path,
                "tags": tags,
                "title": title,
            })
            result = data["pages"]["create"]["responseResult"]
            if result["succeeded"]:
                page_ok += 1
            else:
                print(f"  WARN: /{path}: {result['message']}")
                page_fail += 1
        except Exception as e:
            print(f"  ERROR /{path}: {e}")
            page_fail += 1
        time.sleep(0.1)

    print(f"    pages: {page_ok} created, {page_skip} skipped (exist), {page_fail} failed")
    print("==> Import complete.")

if __name__ == "__main__":
    main()
