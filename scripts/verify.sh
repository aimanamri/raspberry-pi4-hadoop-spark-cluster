#!/usr/bin/env bash
# Check that Java, Hadoop and Spark work together. Run on the MASTER node, as the hadoop user.   (README Part 7)
#
#   ./scripts/verify.sh [--quick]
#
# Checks, in order:
#   1. Java version on every node
#   2. Hadoop and Spark versions
#   3. Expected daemons (jps) on every node
#   4. HDFS: write, read and delete a file
#   5. YARN: the Hadoop "pi" example job
#   6. Spark: the SparkPi example on YARN
# --quick skips the two job checks (5 and 6).
# The script prints PASS or FAIL for each check and a summary at the end. The exit code is 0 only if all checks pass.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QUICK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --quick)   QUICK=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

load_env
require_user
require_master
load_cluster_env

PASS=0; FAIL=0; FAILED_NAMES=""
check() {   # check "name" command...
  local name="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then
    PASS=$((PASS+1)); printf '%sPASS%s %s\n' "$C_GRN" "$C_OFF" "$name"
    [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/       /' | tail -3
  else
    FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES\n  - $name"
    printf '%sFAIL%s %s\n' "$C_RED" "$C_OFF" "$name"
    printf '%s\n' "$out" | sed 's/^/       /' | tail -15
  fi
}

# ---- helpers used by the checks
java_major_on() {   # node
  local v
  if [ "$1" = "$MASTER_HOST" ]; then v="$("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"
  else v="$(node_ssh "$1" "$JAVA_HOME/bin/java -version 2>&1 | head -1")"; fi
  echo "$v"
  case "$v" in *"\"$JAVA_VERSION"*) return 0 ;; *) return 1 ;; esac
}

expect_jps() {      # node process...
  local n="$1"; shift
  local out p
  if [ "$n" = "$MASTER_HOST" ]; then out="$("$JAVA_HOME/bin/jps")"; else out="$(node_ssh "$n" "$JAVA_HOME/bin/jps")"; fi || return 1
  for p in "$@"; do
    printf '%s\n' "$out" | grep -qw "$p" || { echo "$n: $p is not running"; return 1; }
  done
  echo "$n: $*"
}

hdfs_roundtrip() {
  local f="/pi-cluster-check-$$.txt"
  echo "hello hdfs" > "/tmp/pi-cluster-check-$$.txt" || return 1
  hdfs dfs -put -f "/tmp/pi-cluster-check-$$.txt" "$f" || return 1
  local got; got="$(hdfs dfs -cat "$f")" || return 1
  hdfs dfs -rm -f "$f" >/dev/null; rm -f "/tmp/pi-cluster-check-$$.txt"
  [ "$got" = "hello hdfs" ] || { echo "Read back: '$got'"; return 1; }
  echo "wrote, read and deleted $f"
}

hadoop_pi() {
  local jar="$HADOOP_HOME/share/hadoop/mapreduce/hadoop-mapreduce-examples-$HADOOP_VERSION.jar"
  [ -f "$jar" ] || { echo "Not found: $jar"; return 1; }
  # The queue is needed: capacity-scheduler.xml has only the prod and dev queues, so the default queue does not exist.
  timeout 900 yarn jar "$jar" pi "-Dmapreduce.job.queuename=${VERIFY_QUEUE:-dev}" 2 10 2>&1 | tee /tmp/pi-cluster-pi.log | grep -q "Estimated value of Pi" || { tail -15 /tmp/pi-cluster-pi.log; return 1; }
  grep "Estimated value of Pi" /tmp/pi-cluster-pi.log
}

spark_pi() {
  local jar; jar="$(ls "$SPARK_HOME"/examples/jars/spark-examples_*.jar 2>/dev/null | head -1)"
  [ -n "$jar" ] || { echo "No spark-examples jar in $SPARK_HOME/examples/jars"; return 1; }
  # timeout: a job that waits for memory that YARN cannot give would run forever
  timeout 900 spark-submit --class org.apache.spark.examples.SparkPi --master yarn --queue "${VERIFY_QUEUE:-dev}" "$jar" 10 > /tmp/pi-cluster-sparkpi.log 2>&1
  grep "Pi is roughly" /tmp/pi-cluster-sparkpi.log && return 0
  tail -15 /tmp/pi-cluster-sparkpi.log; return 1
}

# ---- run the checks
log "Check Java $JAVA_VERSION on each node"
for n in $(all_nodes); do check "Java $JAVA_VERSION on $n" java_major_on "$n"; done

log "Check versions"
check "Hadoop $HADOOP_VERSION" bash -c "hadoop version | head -1 | grep -q '$HADOOP_VERSION' && hadoop version | head -1"
[ -d "$SPARK_DIR" ] && check "Spark $SPARK_VERSION" bash -c "spark-submit --version 2>&1 | grep -m1 'version $SPARK_VERSION'"

log "Check the daemons"
check "Master daemons" expect_jps "$MASTER_HOST" NameNode SecondaryNameNode ResourceManager
for n in $WORKER_HOSTS; do check "Worker daemons on $n" expect_jps "$n" DataNode NodeManager; done
[ -d "$SPARK_DIR" ] && check "Spark History Server" expect_jps "$MASTER_HOST" HistoryServer

log "Check HDFS"
check "HDFS write, read, delete" hdfs_roundtrip

if [ "$QUICK" = "1" ]; then
  warn "--quick: skip the job checks."
else
  log "Run the example jobs (this takes a few minutes)"
  check "YARN: Hadoop pi example" hadoop_pi
  [ -d "$SPARK_DIR" ] && check "Spark: SparkPi on YARN (queue ${VERIFY_QUEUE:-dev})" spark_pi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  ok "All $PASS checks passed. Java, Hadoop and Spark work together."
  exit 0
fi
printf '%s%d check(s) failed, %d passed.%s\nFailed:' "$C_RED" "$FAIL" "$PASS" "$C_OFF"
printf '%b\n' "$FAILED_NAMES"
exit 1
