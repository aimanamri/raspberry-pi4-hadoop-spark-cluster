#!/usr/bin/env bash
# Start or stop HDFS, YARN and the Spark History Server. Run on the MASTER node, as the hadoop user.   (README Part 4 and 5.4)
#
#   ./scripts/start-cluster.sh              start (formats HDFS the first time)
#   ./scripts/start-cluster.sh --stop       stop everything
#   ./scripts/start-cluster.sh --reformat   format HDFS again. THIS DELETES ALL DATA IN HDFS.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE=start
while [ $# -gt 0 ]; do
  case "$1" in
    --stop)     MODE=stop; shift ;;
    --reformat) MODE=reformat; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  sed -n '2,7p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

load_env
require_user
require_master
load_cluster_env
[ -d "$HADOOP_DIR" ] || die "Hadoop is not installed. Run scripts/install-hadoop.sh first."

show_processes() {
  local n
  for n in $(all_nodes); do
    echo "--- $n"
    if [ "$n" = "$MASTER_HOST" ]; then "$JAVA_HOME/bin/jps"; else node_ssh "$n" "$JAVA_HOME/bin/jps"; fi
  done
}

if [ "$MODE" = "stop" ]; then
  log "Stop the Spark History Server, YARN and HDFS"
  [ -d "$SPARK_DIR" ] && { run "$SPARK_DIR/sbin/stop-history-server.sh" || true; }
  run "$HADOOP_DIR/sbin/stop-yarn.sh" || true
  run "$HADOOP_DIR/sbin/stop-dfs.sh" || true
  ok "Stopped."
  exit 0
fi

NAMENODE_DIR="$HDFS_DATA_DIR/namenode"
if [ "$MODE" = "reformat" ]; then
  warn "This deletes ALL data in HDFS."
  printf 'Type YES to continue: '
  read -r answer
  [ "$answer" = "YES" ] || die "Cancelled."
  run "$HADOOP_DIR/sbin/stop-dfs.sh" || true
  run rm -rf "$NAMENODE_DIR/current"
fi

if [ -f "$NAMENODE_DIR/current/VERSION" ]; then
  ok "HDFS is already formatted. Skip the format step."
else
  log "Format HDFS"
  run hdfs namenode -format -nonInteractive
fi

log "Start HDFS and YARN"
run "$HADOOP_DIR/sbin/start-dfs.sh"
run "$HADOOP_DIR/sbin/start-yarn.sh"

if [ -d "$SPARK_DIR" ]; then
  log "Create the Spark event log folder in HDFS and start the History Server"
  # HDFS stays in safe mode for a short time after the start
  run hdfs dfsadmin -safemode wait
  run hdfs dfs -mkdir -p "${SPARK_LOG_DIR_HDFS:-/spark-logs}"
  run "$SPARK_DIR/sbin/start-history-server.sh"
fi

[ "$DRY_RUN" = "1" ] || show_processes
echo
ok "Started. Web pages:"
echo "  HDFS            http://$MASTER_HOST:9870"
echo "  YARN            http://$MASTER_HOST:8088"
echo "  Spark History   http://$MASTER_HOST:${SPARK_HISTORY_PORT:-18080}"
echo "Next: ./scripts/verify.sh"
