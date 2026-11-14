#!/bin/sh
# Starts integration-test servers (Docker), bound to 127.0.0.1:13300–13399, 384 MB each.
#   scripts/it-up.sh m80 m84 mariadb1011 ...      (see the table below; `all-basic` = the version matrix)
# Containers are named ccinnmysql-it-<target>; stop them with scripts/it-down.sh.
# Images come from public.ecr.aws/docker/library (Docker Hub mirror without pull limits) unless overridden
# with CCINNMYSQL_IT_REGISTRY (e.g. "docker.io/library").
set -eu
REGISTRY="${CCINNMYSQL_IT_REGISTRY:-public.ecr.aws/docker/library}"
NETWORK=ccinnmysql-it-net
PASSWORD=ccinn-root-pw
MEMORY=384m
# Keeps MySQL 8+/9 inside 384 MB.
SMALL_MYSQL="--innodb-buffer-pool-size=32M --performance-schema-max-digest-length=1024 --performance-schema-digests-size=2000 \
--performance-schema-events-statements-history-long-size=1000 --performance-schema-max-table-instances=500 \
--performance-schema-max-thread-instances=200 --max-connections=80"
SMALL_MARIADB="--innodb-buffer-pool-size=32M --performance-schema=ON --max-connections=80"

docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK" >/dev/null

run() { # name port image env... -- args...
  name="ccinnmysql-it-$1"; port="$2"; image="$3"; shift 3
  if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then echo "$name exists"; return; fi
  envs=""
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs="$envs -e $1"; shift; done
  [ $# -gt 0 ] && shift
  # shellcheck disable=SC2086
  docker run -d --name "$name" --network "$NETWORK" --network-alias "$name" --memory "$MEMORY" \
    -p "127.0.0.1:$port:3306" $envs "$image" "$@" >/dev/null
  echo "started $name on 127.0.0.1:$port ($image)"
}

for target in "$@"; do
  case "$target" in
    all-basic) set -- m57 m80 m84 m96 mariadb106 mariadb1011 mariadb114 mariadb120 percona80 ;;
  esac
done

for target in "$@"; do
  case "$target" in
    all-basic) ;;
    m55) run m55 13355 "${CCINNMYSQL_IT_LEGACY_REGISTRY:-docker.io/library}/mysql:5.5" MYSQL_ROOT_PASSWORD=$PASSWORD -- --innodb-buffer-pool-size=32M --performance-schema=ON ;;
    m56) run m56 13356 "${CCINNMYSQL_IT_LEGACY_REGISTRY:-docker.io/library}/mysql:5.6" MYSQL_ROOT_PASSWORD=$PASSWORD -- --innodb-buffer-pool-size=32M --performance-schema=ON ;;
    m57) run m57 13357 "$REGISTRY/mysql:5.7" MYSQL_ROOT_PASSWORD=$PASSWORD -- --innodb-buffer-pool-size=32M --performance-schema=ON \
           --server-id=57 --log-bin=mysql-bin --gtid-mode=ON --enforce-gtid-consistency=ON ;;
    m80) run m80 13380 "$REGISTRY/mysql:8.0" MYSQL_ROOT_PASSWORD=$PASSWORD -- $SMALL_MYSQL ;;
    m84) run m84 13384 "$REGISTRY/mysql:8.4" MYSQL_ROOT_PASSWORD=$PASSWORD -- $SMALL_MYSQL --mysql-native-password=ON \
           --server-id=1 --gtid-mode=ON --enforce-gtid-consistency=ON ;;
    r84) run r84 13386 "$REGISTRY/mysql:8.4" MYSQL_ROOT_PASSWORD=$PASSWORD -- $SMALL_MYSQL --server-id=2 \
           --gtid-mode=ON --enforce-gtid-consistency=ON --read-only=ON ;;
    gr84) run gr84 13387 "$REGISTRY/mysql:8.4" MYSQL_ROOT_PASSWORD=$PASSWORD -- $SMALL_MYSQL --server-id=3 \
           --gtid-mode=ON --enforce-gtid-consistency=ON --plugin-load-add=group_replication.so \
           --group-replication-group-name=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee --group-replication-start-on-boot=OFF \
           --group-replication-local-address=ccinnmysql-it-gr84:33061 --group-replication-group-seeds=ccinnmysql-it-gr84:33061 \
           --group-replication-bootstrap-group=OFF ;;
    m96) run m96 13396 "$REGISTRY/mysql:9.6" MYSQL_ROOT_PASSWORD=$PASSWORD -- $SMALL_MYSQL ;;
    mariadb106) run mariadb106 13316 "$REGISTRY/mariadb:10.6" MARIADB_ROOT_PASSWORD=$PASSWORD -- $SMALL_MARIADB ;;
    mariadb1011) run mariadb1011 13321 "$REGISTRY/mariadb:10.11" MARIADB_ROOT_PASSWORD=$PASSWORD -- $SMALL_MARIADB \
           --server-id=11 --log-bin=mariadb-bin ;;
    mariadb114) run mariadb114 13314 "$REGISTRY/mariadb:11.4" MARIADB_ROOT_PASSWORD=$PASSWORD -- $SMALL_MARIADB ;;
    mariadb120) run mariadb120 13312 "$REGISTRY/mariadb:12.0" MARIADB_ROOT_PASSWORD=$PASSWORD -- $SMALL_MARIADB ;;
    galera) run galera 13340 "$REGISTRY/mariadb:11.4" MARIADB_ROOT_PASSWORD=$PASSWORD -- $SMALL_MARIADB \
           --wsrep-on=ON --wsrep-provider=/usr/lib/galera/libgalera_smm.so --wsrep-cluster-address=gcomm:// \
           --wsrep-cluster-name=ccinn --binlog-format=ROW --innodb-autoinc-lock-mode=2 --wsrep-new-cluster ;;
    percona80) run percona80 13381 "$REGISTRY/percona:8.0" MYSQL_ROOT_PASSWORD=$PASSWORD -- $SMALL_MYSQL ;;
    proxysql) run proxysql 13360 "${CCINNMYSQL_IT_PROXYSQL_IMAGE:-mirror.gcr.io/proxysql/proxysql:2.7.1}" -- ;;
    *) echo "unknown target $target" >&2; exit 64 ;;
  esac
done
