#!/usr/bin/env bash
# Install and configure Spark. Run this on the MASTER node, as the hadoop user.   (README Part 5)
#
#   ./scripts/install-spark.sh [--configs-only] [--dry-run]
#
# What it does:
#   1. Downloads Spark (build for Hadoop 3), checks the SHA-512 checksum and extracts it.
#   2. Writes conf/spark-defaults.conf (memory, event log, History Server) from scripts/.env.
#   3. Adds Spark to ~/.pi-cluster-env.sh (PATH, SPARK_HOME, PYSPARK_PYTHON).
# Spark runs on YARN, so it is installed on the master only. It does not need the Spark workers file.
# --configs-only writes only the configuration file (no download).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONFIGS_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --configs-only) CONFIGS_ONLY=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      sed -n '2,11p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

load_env
if [ "$CONFIGS_ONLY" != "1" ]; then require_user; require_master; fi
require_arch
load_cluster_env
JAVA_HOME_PATH="$JAVA_HOME"
[ -d "$HADOOP_DIR" ] || [ "$DRY_RUN" = "1" ] || die "Hadoop is not installed. Run scripts/install-hadoop.sh first."
check_python

# ------------------------------------------------------------------ 1. download
if [ "$CONFIGS_ONLY" != "1" ]; then
  if [ -d "$SPARK_DIR" ]; then
    ok "$SPARK_DIR exists. Skip the download."
  else
    NAME="spark-$SPARK_VERSION-bin-hadoop3"
    TMP_DL="$HADOOP_USER_HOME/.pi-cluster-downloads"
    run fetch_apache "$SPARK_DOWNLOAD_BASE" "$SPARK_ARCHIVE_BASE" "spark-$SPARK_VERSION/$NAME.tgz" "$TMP_DL"
    log "Extract $NAME.tgz"
    run tar -xzf "$TMP_DL/$NAME.tgz" -C "$HADOOP_USER_HOME"
    run mv "$HADOOP_USER_HOME/$NAME" "$SPARK_DIR"
    run rm -f "$TMP_DL/$NAME.tgz" "$TMP_DL/$NAME.tgz.sha512"
  fi
fi

# ------------------------------------------------------------------ 2. spark-defaults.conf
if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] write $SPARK_DIR/conf/spark-defaults.conf and update ~/.pi-cluster-env.sh"
else
  [ -d "$SPARK_DIR/conf" ] || die "$SPARK_DIR/conf not found."
  log "Write $SPARK_DIR/conf/spark-defaults.conf"
  cat > "$SPARK_DIR/conf/spark-defaults.conf" <<EOF
# Written by scripts/install-spark.sh from scripts/.env. Run the script again to change it.
spark.driver.memory ${SPARK_DRIVER_MEMORY:-512m}
spark.yarn.am.memory ${SPARK_AM_MEMORY:-512m}
spark.executor.memory ${SPARK_EXECUTOR_MEMORY:-512m}

# Monitor Spark Applications
spark.eventLog.enabled            true
spark.eventLog.dir                hdfs://$MASTER_HOST:$HDFS_PORT${SPARK_LOG_DIR_HDFS:-/spark-logs}
spark.history.provider            org.apache.spark.deploy.history.FsHistoryProvider
spark.history.fs.logDirectory     hdfs://$MASTER_HOST:$HDFS_PORT${SPARK_LOG_DIR_HDFS:-/spark-logs}
spark.history.fs.update.interval  10s
spark.history.ui.port             ${SPARK_HISTORY_PORT:-18080}
EOF
  write_env_file
fi

if [ "$CONFIGS_ONLY" = "1" ]; then ok "Spark configuration written."; exit 0; fi
echo
ok "Spark $SPARK_VERSION is installed in $SPARK_DIR."
echo "Next: ./scripts/start-cluster.sh"
