#!/bin/sh
# Waits until the named targets accept TCP connections on port 3306 inside the container (max 240 s each).
set -u
for target in "$@"; do
  name="ccinnmysql-it-$target"
  for _ in $(seq 1 120); do
    if docker logs "$name" 2>&1 | grep -q "port: 3306"; then echo "ready $name"; break; fi
    if [ "$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null)" = "exited" ]; then
      echo "EXITED $name (OOM=$(docker inspect -f '{{.State.OOMKilled}}' "$name"))"; break
    fi
    sleep 2
  done
done
