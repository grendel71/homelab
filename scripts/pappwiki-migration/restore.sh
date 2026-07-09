#!/usr/bin/env bash
set -euo pipefail

DUMP_DIR="${DUMP_DIR:-$HOME/PappWikiDump}"
WORK_DIR="${WORK_DIR:-$HOME/pappwiki-migration-work}"
CONTAINER_NAME="pappwiki-mariadb-restore"

echo "==> Creating work dir $WORK_DIR"
mkdir -p "$WORK_DIR/images" "$WORK_DIR/converted" "$WORK_DIR/xml"

echo "==> Extracting images and LocalSettings.php from wikidata.tgz"
tar -xzf "$DUMP_DIR/wikidata.tgz" \
  -C "$WORK_DIR" \
  --strip-components=1 \
  "wiki/images" \
  "wiki/LocalSettings.php"
# wikidata.tgz extracts wiki/images/ → $WORK_DIR/images/
[ -f "$WORK_DIR/LocalSettings.php" ] || { echo "ERROR: LocalSettings.php not extracted from wikidata.tgz"; exit 1; }
[ -d "$WORK_DIR/images" ] || { echo "ERROR: wiki/images not extracted from wikidata.tgz"; exit 1; }

echo "==> Starting MariaDB container: $CONTAINER_NAME"
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
docker run -d \
  --name "$CONTAINER_NAME" \
  -e MYSQL_ROOT_PASSWORD=restore \
  -e MYSQL_DATABASE=papp_wiki \
  -p 33306:3306 \
  mariadb:10.3 \
  --character-set-server=binary \
  --collation-server=binary

echo "==> Waiting for MariaDB to be ready..."
for i in $(seq 1 30); do
  if docker exec "$CONTAINER_NAME" mysqladmin ping -h 127.0.0.1 -uroot -prestore --silent 2>/dev/null; then
    echo "MariaDB ready."
    break
  fi
  sleep 2
  if [ "$i" -eq 30 ]; then echo "ERROR: MariaDB did not become ready in time"; exit 1; fi
done

echo "==> Loading backup.sql (this may take a minute)..."
docker exec -i "$CONTAINER_NAME" mysql -uroot -prestore papp_wiki < "$DUMP_DIR/backup.sql"

PAGE_COUNT=$(docker exec "$CONTAINER_NAME" mysql -uroot -prestore -sN papp_wiki \
  -e "SELECT COUNT(*) FROM page WHERE page_namespace=0;")
echo "==> Restored. Content pages (namespace 0): $PAGE_COUNT"
echo ""
echo "Container '$CONTAINER_NAME' is running on 127.0.0.1:33306"
echo "Run export.sh next."
