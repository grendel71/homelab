#!/usr/bin/env python3
"""
Import converted pages and images into Wiki.js via GraphQL API.

Usage:
  python3 import.py --url https://papp.envoy.grendel71.net --token <api-key> \
                    --pages ~/pappwiki-migration-work/converted \
                    --images ~/pappwiki-migration-work/images

Idempotent: pages/assets that already exist are skipped.
Uses only stdlib (urllib) — no third-party packages needed.
"""
import argparse, os, sys, re, pathlib, json, time
import urllib.request, urllib.error
from email.mime.multipart import MIMEMultipart
from email.mime.base import MIMEBase
import mimetypes, uuid

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from normalize import normalize_path, normalize_asset_name

# ---------------------------------------------------------------------------
# HTTP helpers (stdlib urllib, no requests)
# ---------------------------------------------------------------------------

def http_post_json(url: str, token: str, payload: dict, timeout: int = 30) -> dict:
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = json.loads(resp.read().decode())
    return body

def http_post_multipart(url: str, token: str, fields: dict, files: dict, timeout: int = 60) -> tuple:
    """
    Simple multipart/form-data POST using stdlib only.
    fields: {name: str_value}
    files:  {name: (filename, bytes_or_path, content_type)}
    Returns (status_code, response_body_str).
    """
    boundary = uuid.uuid4().hex
    ctype = f"multipart/form-data; boundary={boundary}"

    body_parts = []
    for name, value in fields.items():
        body_parts.append(
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="{name}"\r\n\r\n'
            f"{value}\r\n"
        )
    for name, (filename, file_data, file_ctype) in files.items():
        if isinstance(file_data, (str, pathlib.Path)):
            with open(file_data, "rb") as f:
                file_data = f.read()
        header = (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'
            f"Content-Type: {file_ctype}\r\n\r\n"
        )
        body_parts.append(header.encode() + file_data + b"\r\n")

    closing = f"--{boundary}--\r\n"
    raw = b""
    for part in body_parts:
        raw += part if isinstance(part, bytes) else part.encode()
    raw += closing.encode()

    req = urllib.request.Request(
        url,
        data=raw,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": ctype,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")

# ---------------------------------------------------------------------------
# GraphQL helpers
# ---------------------------------------------------------------------------

def gql(url: str, token: str, query: str, variables: dict = None) -> dict:
    payload = {"query": query, "variables": variables or {}}
    body = http_post_json(f"{url}/graphql", token, payload)
    if "errors" in body:
        raise RuntimeError(f"GraphQL error: {body['errors']}")
    return body["data"]

LIST_PAGES_QUERY = """
query { pages { list { path } } }
"""

CREATE_PAGE_MUTATION = """
mutation CreatePage($content: String!, $description: String!, $editor: String!,
                    $isPublished: Boolean!, $isPrivate: Boolean!, $locale: String!, $path: String!,
                    $tags: [String]!, $title: String!) {
  pages {
    create(content: $content, description: $description, editor: $editor,
           isPublished: $isPublished, isPrivate: $isPrivate, locale: $locale, path: $path,
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

def upload_asset(url: str, token: str, filepath: pathlib.Path, folder_id: int, upload_name: str = None) -> bool:
    """Upload a single file as a Wiki.js asset. Returns True on success."""
    name = upload_name or filepath.name
    mime = mimetypes.guess_type(name)[0] or "application/octet-stream"
    status, body = http_post_multipart(
        f"{url}/u",
        token,
        fields={"mediaUpload": json.dumps({"folderId": folder_id})},
        files={"mediaUpload": (name, filepath, mime)},
    )
    if status == 200:
        return True
    print(f"  WARN: asset upload returned {status} for {filepath.name}: {body[:200]}")
    return False

# ---------------------------------------------------------------------------
# Front-matter parser
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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

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

    asset_ok = asset_fail = 0
    for img in sorted(image_files):
        new_name = normalize_asset_name(img.name)
        if args.dry_run:
            print(f"    [dry] would upload {img.name} → images/{new_name}")
            asset_ok += 1
            continue
        try:
            success = upload_asset(url, token, img, folder_id, upload_name=new_name)
            if success:
                asset_ok += 1
            else:
                asset_fail += 1
        except Exception as e:
            print(f"  ERROR uploading {img.name}: {e}")
            asset_fail += 1
        time.sleep(0.05)   # gentle rate-limit

    print(f"    assets: {asset_ok} uploaded, {asset_fail} failed")

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
                "isPrivate": False,
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
