#!/usr/bin/env bash
# Pull the images named in .env (REGISTRY/TAG) and (re)start the stack.
# Run on the VM from /opt/ansvisor.
set -euo pipefail

cd "$(dirname "$0")"

for f in docker-compose.yml .env web.env server.env; do
  if [[ ! -f "$f" ]]; then
    echo "error: missing $(pwd)/$f" >&2
    exit 1
  fi
done

docker compose pull
docker compose up -d

docker compose ps
echo
echo "--- last 50 server log lines ---"
docker compose logs --tail 50 server
