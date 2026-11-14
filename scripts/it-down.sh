#!/bin/sh
# Removes integration-test containers (all ccinnmysql-it-*, or the named targets) and, when none remain, the network.
set -eu
if [ $# -eq 0 ]; then
  names=$(docker ps -a --format '{{.Names}}' | grep '^ccinnmysql-it-' || true)
else
  names=$(for target in "$@"; do echo "ccinnmysql-it-$target"; done)
fi
[ -n "$names" ] && docker rm -f $names >/dev/null 2>&1 || true
if ! docker ps -a --format '{{.Names}}' | grep -q '^ccinnmysql-it-'; then
  docker network rm ccinnmysql-it-net >/dev/null 2>&1 || true
fi
echo "removed: $(echo $names | tr '\n' ' ')"
