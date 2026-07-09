#!/usr/bin/env bash
set -euo pipefail

WORK_DIR="${WORK_DIR:-$HOME/pappwiki-migration-work}"
CONTAINER_NAME="pappwiki-mariadb-restore"
MW_CONTAINER="pappwiki-mw-export"

# Verify restore container is up
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "ERROR: Restore container '$CONTAINER_NAME' is not running. Run restore.sh first."
  exit 1
fi

DB_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER_NAME")

echo "==> Starting MediaWiki 1.41 export container..."
docker rm -f "$MW_CONTAINER" 2>/dev/null || true
docker run -d \
  --name "$MW_CONTAINER" \
  -e MYSQL_DATABASE=papp_wiki \
  -e MYSQL_USER=root \
  -e MYSQL_PASSWORD=restore \
  -e MYSQL_HOST="$DB_IP" \
  --add-host="pappwiki-db-svc:$DB_IP" \
  -v "$WORK_DIR/xml:/xml" \
  mediawiki:1.41 \
  sleep infinity

echo "==> Copying LocalSettings.php for dumpBackup.php..."
docker cp "$WORK_DIR/LocalSettings.php" "$MW_CONTAINER:/var/www/html/LocalSettings.php"

# Patch LocalSettings: fix DB connection to point at restore container
# Handles both the k8s configmap form (getenv/pappwiki-db-svc) and
# the original production form (hardcoded localhost/papp/papp)
docker exec "$MW_CONTAINER" sed -i \
  -e "s|pappwiki-db-svc|$DB_IP|g" \
  -e "s|getenv('MYSQL_USER')|'root'|g" \
  -e "s|getenv('MYSQL_PASSWORD')|'restore'|g" \
  -e "s|getenv('MYSQL_DATABASE')|'papp_wiki'|g" \
  -e "s|\(\\\$wgDBserver\s*=\s*\)\"localhost\";|\1\"$DB_IP\";|" \
  -e "s|\(\\\$wgDBserver\s*=\s*\)'localhost';|\1'$DB_IP';|" \
  -e "s|\(\\\$wgDBuser\s*=\s*\)\"papp\";|\1\"root\";|" \
  -e "s|\(\\\$wgDBuser\s*=\s*\)'papp';|\1'root';|" \
  -e "s|\(\\\$wgDBpassword\s*=\s*\)\"papp\";|\1\"restore\";|" \
  -e "s|\(\\\$wgDBpassword\s*=\s*\)'papp';|\1'restore';|" \
  /var/www/html/LocalSettings.php
# Comment out extensions not present in stock mediawiki:1.41 image
# (dumpBackup only needs DB access, not these extensions)
docker exec "$MW_CONTAINER" sed -i \
  -e "s|^\(wfLoadExtension[^']*'TemplateStyles'\)|// \1|" \
  -e "s|^\(wfLoadExtension[^']*'MsUpload'\)|// \1|" \
  -e "s|^\(wfLoadExtension[^']*'Popups'\)|// \1|" \
  -e "s|^\(wfLoadExtension[^']*'PluggableAuth'\)|// \1|" \
  -e "s|^\(wfLoadExtension[^']*'OpenIDConnect'\)|// \1|" \
  /var/www/html/LocalSettings.php

echo "==> Extracting wikitext pages directly via SQL (bypasses content model issues)..."
# dumpBackup trips over sanitized-css content model from TemplateStyles pages in other namespaces.
# Instead, extract namespace-0 wikitext directly from the DB and write minimal MW XML.
docker exec "$CONTAINER_NAME" mysql -uroot -prestore -sN --default-character-set=binary papp_wiki -e "
SELECT p.page_title, t.old_text
FROM page p
JOIN revision r ON r.rev_id = p.page_latest
JOIN slots sl ON sl.slot_revision_id = r.rev_id AND sl.slot_role_id = 1
JOIN content c ON c.content_id = sl.slot_content_id
JOIN content_models cm ON cm.model_id = c.content_model AND cm.model_name = 'wikitext'
JOIN text t ON t.old_id = CAST(SUBSTRING(c.content_address, 4) AS UNSIGNED)
WHERE p.page_namespace = 0
ORDER BY p.page_id;" 2>/dev/null > "$WORK_DIR/xml/pages_raw.tsv"

ROW_COUNT=$(wc -l < "$WORK_DIR/xml/pages_raw.tsv")
echo "==> SQL extracted $ROW_COUNT wikitext rows"

# Build minimal MediaWiki XML from TSV
PYTHON="${PYTHON:-$(command -v python3 2>/dev/null || echo 'nix run nixpkgs#python3 --')}"
$PYTHON - "$WORK_DIR/xml/pages_raw.tsv" "$WORK_DIR/xml/pages.xml" << 'PYEOF'
import sys, xml.etree.ElementTree as ET

tsv_path, xml_path = sys.argv[1], sys.argv[2]

lines = open(tsv_path, 'rb').read().decode('utf-8', errors='replace').split('\n')

with open(xml_path, 'w', encoding='utf-8') as out:
    out.write('<?xml version="1.0" encoding="UTF-8"?>\n')
    out.write('<mediawiki xmlns="http://www.mediawiki.org/xml/export-0.11/">\n')
    out.write('  <siteinfo><sitename>PAPP</sitename></siteinfo>\n')
    count = 0
    for line in lines:
        if not line.strip():
            continue
        # TSV: title \t content_address \t wikitext
        # wikitext may contain tabs — split on first two only
        parts = line.split('\t', 2)
        if len(parts) < 3:
            continue
        title, _addr, wikitext = parts
        # Escape XML special chars
        title_esc = title.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')
        text_esc = wikitext.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')
        out.write(f'  <page>\n')
        out.write(f'    <title>{title_esc}</title>\n')
        out.write(f'    <ns>0</ns>\n')
        out.write(f'    <revision>\n')
        out.write(f'      <text xml:space="preserve">{text_esc}</text>\n')
        out.write(f'    </revision>\n')
        out.write(f'  </page>\n')
        count += 1
    out.write('</mediawiki>\n')

print(f"Written {count} pages to XML")
PYEOF

docker stop "$MW_CONTAINER" && docker rm "$MW_CONTAINER"

PAGE_COUNT=$(grep -c '<page>' "$WORK_DIR/xml/pages.xml" 2>/dev/null || echo 0)
echo "==> Export complete: $PAGE_COUNT pages written to $WORK_DIR/xml/pages.xml"
