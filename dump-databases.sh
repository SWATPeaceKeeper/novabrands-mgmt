#!/usr/bin/env bash
set -euo pipefail

DUMP_DIR="/opt/containers/novabrands-mgmt/db-dumps"
mkdir -p "$DUMP_DIR"

echo "=== Dumping OpenProject DB ==="
docker exec openproject-db pg_dump \
  -U openproject \
  -d openproject \
  --format=custom \
  --file=/tmp/openproject.dump
docker cp openproject-db:/tmp/openproject.dump "$DUMP_DIR/openproject.dump"
docker exec openproject-db rm /tmp/openproject.dump

echo "=== Putting Nextcloud in Maintenance Mode ==="
docker exec -u www-data nextcloud php occ maintenance:mode --on

echo "=== Dumping Nextcloud DB ==="
docker exec nextcloud-db pg_dump \
  -U nextcloud \
  -d nextcloud \
  --format=custom \
  --file=/tmp/nextcloud.dump
docker cp nextcloud-db:/tmp/nextcloud.dump "$DUMP_DIR/nextcloud.dump"
docker exec nextcloud-db rm /tmp/nextcloud.dump

echo "=== Disabling Nextcloud Maintenance Mode ==="
docker exec -u www-data nextcloud php occ maintenance:mode --off

echo "=== Dumping Coder DB ==="
docker exec coder-db pg_dump \
  -U coder \
  -d coder \
  --format=custom \
  --file=/tmp/coder.dump
docker cp coder-db:/tmp/coder.dump "$DUMP_DIR/coder.dump"
docker exec coder-db rm /tmp/coder.dump

echo "=== Dumps created in $DUMP_DIR ==="
