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

# Patch LocalSettings to point at the restore container's IP
docker exec "$MW_CONTAINER" sed -i \
  "s|pappwiki-db-svc|$DB_IP|g; s|getenv('MYSQL_USER')|'root'|g; s|getenv('MYSQL_PASSWORD')|'restore'|g; s|getenv('MYSQL_DATABASE')|'papp_wiki'|g" \
  /var/www/html/LocalSettings.php

echo "==> Running dumpBackup.php --current (namespace 0 only)..."
docker exec "$MW_CONTAINER" php /var/www/html/maintenance/run.php \
  dumpBackup \
  --current \
  --namespace=0 \
  --output="file:/xml/pages.xml" \
  --quiet

docker stop "$MW_CONTAINER" && docker rm "$MW_CONTAINER"

PAGE_COUNT=$(grep -c '<page>' "$WORK_DIR/xml/pages.xml" || true)
echo "==> Export complete: $PAGE_COUNT pages written to $WORK_DIR/xml/pages.xml"
