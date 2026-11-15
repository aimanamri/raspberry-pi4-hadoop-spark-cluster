#!/usr/bin/env bash
# Install and configure Hadoop. Run this on the MASTER node, as the hadoop user.   (README Part 3)
#
#   ./scripts/install-hadoop.sh [--configs-only] [--dry-run]
#
# What it does:
#   1. Downloads Hadoop (aarch64 build), checks the SHA-512 checksum and extracts it.
#   2. Writes core-site.xml, hdfs-site.xml, mapred-site.xml, yarn-site.xml and workers
#      from the values in scripts/.env. It copies capacity-scheduler.xml from config_files/.
#   3. Sets JAVA_HOME in hadoop-env.sh and in ~/.pi-cluster-env.sh.
#   4. Creates the HDFS folders and copies Hadoop and the settings to the worker nodes.
# Run setup-node.sh on all Pis and setup-ssh.sh on the master first.
# --configs-only writes only the configuration files (no download, no copy to workers).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONFIGS_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --configs-only) CONFIGS_ONLY=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      sed -n '2,14p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

load_env
if [ "$CONFIGS_ONLY" != "1" ]; then require_user; require_master; fi
require_arch
load_cluster_env
# JAVA_HOME_PATH is what write_env_file saves
JAVA_HOME_PATH="$JAVA_HOME"
[ -x "$JAVA_HOME/bin/java" ] || die "Java not found at $JAVA_HOME. Run scripts/setup-node.sh first."

# ------------------------------------------------------------------ 1. download
if [ "$CONFIGS_ONLY" != "1" ]; then
  if [ -d "$HADOOP_DIR" ]; then
    ok "$HADOOP_DIR exists. Skip the download."
  else
    TARBALL="$(hadoop_tarball)"
    TMP_DL="$HADOOP_USER_HOME/.pi-cluster-downloads"
    run fetch_apache "$HADOOP_DOWNLOAD_BASE" "$HADOOP_ARCHIVE_BASE" "hadoop-$HADOOP_VERSION/$TARBALL" "$TMP_DL"
    log "Extract $TARBALL"
    run tar -xzf "$TMP_DL/$TARBALL" -C "$HADOOP_USER_HOME"
    run rm -f "$TMP_DL/$TARBALL" "$TMP_DL/$TARBALL.sha512"
  fi
fi
[ "$DRY_RUN" = "1" ] || [ -d "$HADOOP_DIR/etc/hadoop" ] || die "$HADOOP_DIR/etc/hadoop not found."

# ------------------------------------------------------------------ 2. configuration files
CONF="$HADOOP_DIR/etc/hadoop"
HEAD='<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<!-- Written by scripts/install-hadoop.sh from scripts/.env. Run the script again to change it. -->'

prop() { printf '    <property>\n        <name>%s</name>\n        <value>%s</value>\n    </property>\n' "$1" "$2"; }

write_configs() {
  log "Write the configuration files to $CONF"
  mkdir -p "$CONF"

  { echo "$HEAD"; echo '<configuration>'
    prop fs.defaultFS "hdfs://$MASTER_HOST:$HDFS_PORT"
    echo '</configuration>'; } > "$CONF/core-site.xml"

  { echo "$HEAD"; echo '<configuration>'
    prop dfs.replication "$HDFS_REPLICATION"
    prop dfs.namenode.name.dir "$HDFS_DATA_DIR/namenode/"
    prop dfs.datanode.data.dir "$HDFS_DATA_DIR/datanode/"
    echo '</configuration>'; } > "$CONF/hdfs-site.xml"

  { echo "$HEAD"; echo '<configuration>'
    prop mapreduce.framework.name yarn
    prop yarn.app.mapreduce.am.env 'HADOOP_MAPRED_HOME=$HADOOP_HOME'
    prop mapreduce.map.env 'HADOOP_MAPRED_HOME=$HADOOP_HOME'
    prop mapreduce.reduce.env 'HADOOP_MAPRED_HOME=$HADOOP_HOME'
    prop yarn.app.mapreduce.am.resource.mb "${MAPRED_AM_MEMORY_MB:-512}"
    prop mapreduce.map.memory.mb "${MAPRED_MAP_MEMORY_MB:-256}"
    prop mapreduce.reduce.memory.mb "${MAPRED_REDUCE_MEMORY_MB:-256}"
    echo '</configuration>'; } > "$CONF/mapred-site.xml"

  { echo "$HEAD"; echo '<configuration>'
    prop yarn.nodemanager.aux-services mapreduce_shuffle
    prop yarn.nodemanager.env-whitelist 'JAVA_HOME,HADOOP_COMMON_HOME,HADOOP_HDFS_HOME,HADOOP_CONF_DIR,CLASSPATH_PREPEND_DISTCACHE,HADOOP_YARN_HOME,HADOOP_HOME,PATH,LANG,TZ,HADOOP_MAPRED_HOME'
    prop yarn.acl.enable 0
    prop yarn.resourcemanager.hostname "$MASTER_HOST"
    prop yarn.nodemanager.resource.memory-mb "${YARN_NODE_MEMORY_MB:-1536}"
    prop yarn.scheduler.maximum-allocation-mb "${YARN_MAX_ALLOCATION_MB:-1536}"
    prop yarn.scheduler.minimum-allocation-mb "${YARN_MIN_ALLOCATION_MB:-128}"
    prop yarn.nodemanager.vmem-check-enabled false
    echo '</configuration>'; } > "$CONF/yarn-site.xml"

  cp "$REPO_DIR/config_files/capacity-scheduler.xml" "$CONF/capacity-scheduler.xml"

  # workers: one host name per line. The master is not a worker.
  { for n in $WORKER_HOSTS; do echo "$n"; done; } > "$CONF/workers"

  # JAVA_HOME for the daemons. SSH sessions do not load ~/.bashrc, so set it here.
  printf 'export JAVA_HOME=%s\n' "$JAVA_HOME" | ensure_block "$CONF/hadoop-env.sh" java
}

if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] write core-site.xml hdfs-site.xml mapred-site.xml yarn-site.xml workers capacity-scheduler.xml hadoop-env.sh"
else
  write_configs
  write_env_file
fi

if [ "$CONFIGS_ONLY" = "1" ]; then ok "Configuration files written."; exit 0; fi

# ------------------------------------------------------------------ 3. folders and copy to all nodes
log "Create the HDFS folders on $(all_nodes)"
for n in $(all_nodes); do
  if [ "$n" = "$MASTER_HOST" ]; then
    run mkdir -p "$HDFS_DATA_DIR/namenode" "$HDFS_DATA_DIR/datanode"
  else
    run node_ssh "$n" "mkdir -p '$HDFS_DATA_DIR/namenode' '$HDFS_DATA_DIR/datanode' '$HADOOP_DIR'"
  fi
done

for n in $WORKER_HOSTS; do
  log "Copy Hadoop to $n"
  run node_ssh "$n" "test -x '$JAVA_HOME/bin/java'" || die "$n: Java not found at $JAVA_HOME. Run scripts/setup-node.sh on $n (use the same JAVA_METHOD on every node)."
  run rsync -ax -e "ssh -o BatchMode=yes" "$HADOOP_DIR/" "$n:$HADOOP_DIR/"
  run scp -q -o BatchMode=yes "$ENV_SH" "$n:$ENV_SH"
  # load the environment file in ~/.bashrc and ~/.profile on the worker
  run node_ssh "$n" 'bash -s' <<'EOS'
for rc in "$HOME/.bashrc" "$HOME/.profile"; do
  grep -q 'pi-cluster:env' "$rc" 2>/dev/null || printf '%s\n%s\n%s\n' \
    '# >>> pi-cluster:env >>>' \
    '[ -f "$HOME/.pi-cluster-env.sh" ] && . "$HOME/.pi-cluster-env.sh"' \
    '# <<< pi-cluster:env <<<' >> "$rc"
done
EOS
done

echo
ok "Hadoop $HADOOP_VERSION is installed and configured on $(all_nodes)."
echo "Next: ./scripts/install-spark.sh, then ./scripts/start-cluster.sh"
