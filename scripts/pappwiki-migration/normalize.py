#!/usr/bin/env python3
"""
Shared normalisation for MediaWiki → Wiki.js path conversion.
Import with: from normalize import normalize_path, normalize_asset_name
"""
import re

def normalize_path(title: str) -> str:
    """
    Convert a MediaWiki page title (e.g. "My Great Page") to a Wiki.js path
    (e.g. "my-great-page").
    Rules:
      - lowercase
      - spaces and underscores → hyphens
      - strip leading/trailing hyphens
      - collapse consecutive hyphens
      - percent-decode common URL escapes first
    """
    import urllib.parse
    title = urllib.parse.unquote(title)
    title = title.lower()
    title = re.sub(r'[ _]+', '-', title)
    title = re.sub(r'[^\w\-]', '', title)   # keep word chars and hyphens
    title = re.sub(r'-+', '-', title)
    title = title.strip('-')
    return title or 'untitled'

def normalize_asset_name(filename: str) -> str:
    """
    Convert a MediaWiki uploaded file name to a Wiki.js asset filename.
    Wiki.js lowercases, collapses spaces, and keeps the extension.
    Rules:
      - percent-decode
      - lowercase
      - spaces and underscores → hyphens
      - collapse consecutive hyphens
    """
    import urllib.parse
    filename = urllib.parse.unquote(filename)
    name, _, ext = filename.rpartition('.')
    name = name.lower()
    name = re.sub(r'[ _]+', '-', name)
    name = re.sub(r'-+', '-', name)
    name = name.strip('-')
    return f"{name}.{ext.lower()}" if ext else name
