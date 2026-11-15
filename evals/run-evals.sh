#!/usr/bin/env bash
# Run the Spark evals on the cluster (YARN). Run this on the MASTER node, as the hadoop user.
#
#   ./evals/run-evals.sh --list
#   ./evals/run-evals.sh --dry-run
#   ./evals/run-evals.sh --lang pyspark --domain finance
#   ./evals/run-evals.sh --lang all --domain all --queue dev --executors 2
#
# What it does:
#   1. Uploads the CSV files from evals/datasets/<domain>/ to HDFS (/evals/<domain>/).
#   2. Runs each selected job (PySpark, Scala or R) on YARN and writes a log per job to evals/results/.
#   3. Prints which hosts ran the Spark JVMs, the YARN application, and the links to the web UIs.
#   4. Prints a PASS / FAIL / SKIP table and checks that the 3 languages give the same numbers.
# Exit code: 0 when no job failed, 1 when a job failed, 2 for a usage or setup error.
# Needs bash 4 or later. Settings: evals/.env.example (copy it to evals/.env to change them).
set -uo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "FAIL This script needs bash 4 or later (this is bash $BASH_VERSION)." >&2
  exit 2
fi

EVALS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAINS_ALL="finance logistics helpdesk moderation restaurant inventory political healthcare energy education"
LANGS_ALL="pyspark scala r"

# ------------------------------------------------------------------ output
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_OFF=""
fi
log()  { printf '%s==>%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
warn() { printf '%sWARN%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%sFAIL%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 2; }

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; cat <<'EOF'

Options:
  --list                     Show the jobs and exit.
  --lang pyspark|scala|r|all Languages to run (default: all). A comma list is allowed: pyspark,r
  --domain NAME|all          Datasets to run (default: all). A comma list is allowed: finance,energy
  --dry-run                  Print the commands. Run nothing.
  --deploy-mode client|cluster  Spark deploy mode (default: client). Scala always runs in client mode.
  --queue NAME               YARN queue (default: dev).
  --executors N              Number of executors (default: 2).
  --master URL               Spark master (default: yarn). Use local[2] only for a quick test.
  --skip-upload              Do not upload the datasets (they are in HDFS already).
  -h, --help                 Show this text.
EOF
}

# ------------------------------------------------------------------ settings
# Order: evals/.env.example, then ../scripts/.env (if it exists), then evals/.env (if it exists).
# A variable that is already set in the shell wins over all files.
SETTING_NAMES="MASTER_HOST HDFS_PORT HDFS_URI HADOOP_USER_HOME HADOOP_VERSION SPARK_VERSION SPARK_HOME HADOOP_HOME \
QUEUE EXECUTORS EXECUTOR_MEMORY EXECUTOR_CORES DRIVER_MEMORY MEMORY_OVERHEAD DEPLOY_MODE SPARK_MASTER \
HDFS_BASE HDFS_OUT SPLIT_BYTES SHUFFLE_PARTITIONS RM_PORT HISTORY_PORT JOB_TIMEOUT"
declare -A PRESET=()
for n in $SETTING_NAMES; do
  if [ -n "${!n+x}" ]; then PRESET[$n]="${!n}"; fi
done
load_file() {
  [ -f "$1" ] || return 0
  set -a
  # shellcheck disable=SC1090
  . "$1"
  set +a
}
load_file "$EVALS_DIR/.env.example"
load_file "$EVALS_DIR/../scripts/.env"
load_file "$EVALS_DIR/.env"
for n in "${!PRESET[@]}"; do printf -v "$n" '%s' "${PRESET[$n]}"; done

MASTER_HOST="${MASTER_HOST:-pi1}"
HDFS_PORT="${HDFS_PORT:-9000}"
HADOOP_USER_HOME="${HADOOP_USER_HOME:-/home/hadoop}"
SPARK_VERSION="${SPARK_VERSION:-4.3.0}"
HADOOP_VERSION="${HADOOP_VERSION:-3.5.0}"
SPARK_HOME="${SPARK_HOME:-$HADOOP_USER_HOME/spark-$SPARK_VERSION}"
HADOOP_HOME="${HADOOP_HOME:-$HADOOP_USER_HOME/hadoop-$HADOOP_VERSION}"
HDFS_URI="${HDFS_URI:-hdfs://$MASTER_HOST:$HDFS_PORT}"
QUEUE="${QUEUE:-dev}"
EXECUTORS="${EXECUTORS:-2}"
EXECUTOR_MEMORY="${EXECUTOR_MEMORY:-512m}"
EXECUTOR_CORES="${EXECUTOR_CORES:-1}"
DRIVER_MEMORY="${DRIVER_MEMORY:-512m}"
MEMORY_OVERHEAD="${MEMORY_OVERHEAD:-256m}"
DEPLOY_MODE="${DEPLOY_MODE:-client}"
SPARK_MASTER="${SPARK_MASTER:-yarn}"
HDFS_BASE="${HDFS_BASE:-/evals}"
HDFS_OUT="${HDFS_OUT:-/evals-out}"
SPLIT_BYTES="${SPLIT_BYTES:-524288}"
SHUFFLE_PARTITIONS="${SHUFFLE_PARTITIONS:-8}"
RM_PORT="${RM_PORT:-8088}"
HISTORY_PORT="${HISTORY_PORT:-18080}"
JOB_TIMEOUT="${JOB_TIMEOUT:-3600}"

# ------------------------------------------------------------------ arguments
LANG_SEL="all"; DOMAIN_SEL="all"; DRY_RUN=0; LIST=0; UPLOAD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --list)        LIST=1; shift ;;
    --lang)        [ $# -ge 2 ] || die "--lang needs a value."; LANG_SEL="$2"; shift 2 ;;
    --domain)      [ $# -ge 2 ] || die "--domain needs a value."; DOMAIN_SEL="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --deploy-mode) [ $# -ge 2 ] || die "--deploy-mode needs a value."; DEPLOY_MODE="$2"; shift 2 ;;
    --queue)       [ $# -ge 2 ] || die "--queue needs a value."; QUEUE="$2"; shift 2 ;;
    --executors)   [ $# -ge 2 ] || die "--executors needs a value."; EXECUTORS="$2"; shift 2 ;;
    --master)      [ $# -ge 2 ] || die "--master needs a value."; SPARK_MASTER="$2"; shift 2 ;;
    --skip-upload) UPLOAD=0; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
done

case "$DEPLOY_MODE" in client|cluster) ;; *) die "--deploy-mode must be client or cluster." ;; esac
case "$EXECUTORS" in ''|*[!0-9]*|0) die "--executors must be a whole number of 1 or more." ;; esac

pick() { # pick <all-list> <selection> <what>  -> prints the chosen words
  local all="$1" sel="$2" what="$3" w out=""
  if [ "$sel" = "all" ]; then printf '%s' "$all"; return; fi
  for w in ${sel//,/ }; do
    case " $all " in *" $w "*) out="$out $w" ;; *) die "Unknown $what '$w'. Choose from: $all, all." ;; esac
  done
  printf '%s' "${out# }"
}
LANGS="$(pick "$LANGS_ALL" "$LANG_SEL" language)" || exit 2
DOMAINS="$(pick "$DOMAINS_ALL" "$DOMAIN_SEL" domain)" || exit 2

job_file() { # job_file <lang> <domain>
  case "$1" in
    pyspark) printf '%s/jobs/pyspark/%s.py' "$EVALS_DIR" "$2" ;;
    scala)   printf '%s/jobs/scala/%s.scala' "$EVALS_DIR" "$2" ;;
    r)       printf '%s/jobs/r/%s.R' "$EVALS_DIR" "$2" ;;
  esac
}

# ------------------------------------------------------------------ --list
if [ "$LIST" = 1 ]; then
  printf '%-12s %-9s %-34s %s\n' DOMAIN LANG JOB DATASET-FILES
  for d in $DOMAINS; do
    files="$(cd "$EVALS_DIR/datasets/$d" 2>/dev/null && ls ./*.csv 2>/dev/null | sed 's#^\./##' | tr '\n' ' ')"
    for l in $LANGS; do
      f="$(job_file "$l" "$d")"
      printf '%-12s %-9s %-34s %s\n' "$d" "$l" "${f#"$EVALS_DIR"/}" "${files:-(missing: run datasets/generate.py)}"
    done
  done
  exit 0
fi

# ------------------------------------------------------------------ helpers
SPARK_SUBMIT="$SPARK_HOME/bin/spark-submit"
SPARK_SHELL="$SPARK_HOME/bin/spark-shell"
if [ -x "$HADOOP_HOME/bin/hdfs" ]; then HDFS_BIN="$HADOOP_HOME/bin/hdfs"; else HDFS_BIN="hdfs"; fi
if [ -x "$HADOOP_HOME/bin/yarn" ]; then YARN_BIN="$HADOOP_HOME/bin/yarn"; else YARN_BIN="yarn"; fi

# Print a command. In dry-run mode the caller does not run it.
show() { printf '  $'; printf ' %q' "$@"; printf '\n'; }

fs() { # fs <mkdir|put|rm|cat> ... : works for hdfs:// and file:// locations
  local op="$1"; shift
  case "$HDFS_URI" in
    file://*)
      case "$op" in
        mkdir) mkdir -p "${1#file://}" ;;
        put)   cp -f "$1" "${2#file://}/" ;;
        rm)    rm -rf "${1#file://}" ;;
        cat)   cat "${1#file://}"/part-* 2>/dev/null ;;
      esac ;;
    *)
      case "$op" in
        mkdir) "$HDFS_BIN" dfs -mkdir -p "$1" ;;
        put)   "$HDFS_BIN" dfs -put -f "$1" "$2/" ;;
        rm)    "$HDFS_BIN" dfs -rm -r -f -skipTrash "$1" >/dev/null 2>&1 ;;
        cat)   "$HDFS_BIN" dfs -cat "$1/part-*" 2>/dev/null ;;
      esac ;;
  esac
}

IN_URI="$HDFS_URI$HDFS_BASE"
OUT_URI="$HDFS_URI$HDFS_OUT"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="$EVALS_DIR/results/$RUN_ID"

# ------------------------------------------------------------------ preflight
R_OK=1; R_WHY=""
PY_OK=1; PY_WHY=""
if [ "$DRY_RUN" = 0 ]; then
  [ -x "$SPARK_SUBMIT" ] || die "$SPARK_SUBMIT not found. Set SPARK_HOME in evals/.env."
  case "$HDFS_URI" in file://*) ;; *) command -v "$HDFS_BIN" >/dev/null 2>&1 || die "The hdfs command is not found. Set HADOOP_HOME in evals/.env." ;; esac
fi
if ! command -v python3 >/dev/null 2>&1; then PY_OK=0; PY_WHY="python3 is not installed on this node."; fi
if ! command -v Rscript >/dev/null 2>&1; then
  R_OK=0; R_WHY="Rscript is not installed on this node. Install R 4.0 or later (sudo apt install r-base-core)."
elif [ ! -d "$SPARK_HOME/R/lib/SparkR" ]; then
  R_OK=0; R_WHY="SparkR is not in $SPARK_HOME/R/lib. This Spark build has no R support."
fi

log "Evals run $RUN_ID"
echo "  master      : $SPARK_MASTER (deploy mode $DEPLOY_MODE, queue $QUEUE, $EXECUTORS executors, $EXECUTOR_MEMORY each)"
echo "  data in     : $IN_URI"
echo "  results out : $OUT_URI"
echo "  logs        : $RESULT_DIR"
echo "  YARN UI     : http://$MASTER_HOST:$RM_PORT    (running and finished applications)"
echo "  Spark UI    : http://$MASTER_HOST:$HISTORY_PORT   (History Server: finished applications, stages, tasks)"
echo "  While a job runs, open the YARN UI and click the application's ApplicationMaster link for the live Spark UI."
[ "$DRY_RUN" = 1 ] && echo "  (dry run: no command is run)"

# ------------------------------------------------------------------ 1. upload
if [ "$UPLOAD" = 1 ]; then
  log "Upload datasets to $IN_URI"
  for d in $DOMAINS; do
    if ! ls "$EVALS_DIR/datasets/$d/"*.csv >/dev/null 2>&1; then
      die "No CSV files in evals/datasets/$d. Run: python3 evals/datasets/generate.py"
    fi
    if [ "$DRY_RUN" = 1 ]; then
      show "$HDFS_BIN" dfs -mkdir -p "$IN_URI/$d"
      show "$HDFS_BIN" dfs -put -f "$EVALS_DIR/datasets/$d/"'*.csv' "$IN_URI/$d/"
      continue
    fi
    fs mkdir "$IN_URI/$d" || die "Cannot create $IN_URI/$d. Are HDFS and the NameNode running?"
    for f in "$EVALS_DIR/datasets/$d/"*.csv; do
      fs put "$f" "$IN_URI/$d" || die "Cannot upload $f to $IN_URI/$d."
    done
    echo "  $d: uploaded"
  done
fi

# ------------------------------------------------------------------ 2. run jobs
declare -A RES_STATUS=() RES_TIME=() RES_SUMMARY=() RES_HOSTS=() RES_APP=() RES_NOTE=()
ALL_HOSTS=""
[ "$DRY_RUN" = 1 ] || mkdir -p "$RESULT_DIR"

build_cmd() { # build_cmd <lang> <domain> : fills the CMD array
  local l="$1" d="$2" f mode="$DEPLOY_MODE"
  f="$(job_file "$l" "$d")"
  local common=(--master "$SPARK_MASTER" --queue "$QUEUE" --num-executors "$EXECUTORS"
    --executor-memory "$EXECUTOR_MEMORY" --executor-cores "$EXECUTOR_CORES" --driver-memory "$DRIVER_MEMORY"
    --conf "spark.executor.memoryOverhead=$MEMORY_OVERHEAD" --conf "spark.yarn.am.memoryOverhead=$MEMORY_OVERHEAD"
    --conf "spark.driver.memoryOverhead=$MEMORY_OVERHEAD"
    --conf "spark.sql.files.maxPartitionBytes=$SPLIT_BYTES" --conf "spark.sql.shuffle.partitions=$SHUFFLE_PARTITIONS"
    --conf spark.ui.showConsoleProgress=false --name "eval-$d-$l")
  case "$SPARK_MASTER" in yarn*) ;; *) common=(--master "$SPARK_MASTER" --driver-memory "$DRIVER_MEMORY"
    --conf "spark.sql.files.maxPartitionBytes=$SPLIT_BYTES" --conf "spark.sql.shuffle.partitions=$SHUFFLE_PARTITIONS"
    --conf spark.ui.showConsoleProgress=false --name "eval-$d-$l"); mode="client" ;; esac
  case "$l" in
    pyspark) CMD=("$SPARK_SUBMIT" "${common[@]}" --deploy-mode "$mode" "$f" "$IN_URI" "$OUT_URI") ;;
    r)       CMD=("$SPARK_SUBMIT" "${common[@]}" --deploy-mode "$mode" "$f" "$IN_URI" "$OUT_URI") ;;
    scala)   CMD=("$SPARK_SHELL" "${common[@]}" --deploy-mode client
               --conf "spark.eval.input=$IN_URI" --conf "spark.eval.output=$OUT_URI" -i "$f") ;;
  esac
}

summary_value() { # summary_value <line> <key>
  local w
  for w in $1; do case "$w" in "$2="*) printf '%s' "${w#*=}"; return ;; esac; done
}

run_job() { # run_job <lang> <domain>
  local l="$1" d="$2" key="$1/$2" logf start end rc=0 text="" app="" f
  f="$(job_file "$l" "$d")"
  logf="$RESULT_DIR/$d-$l.log"
  [ -f "$f" ] || { RES_STATUS[$key]=FAIL; RES_NOTE[$key]="job file missing"; return; }
  if [ "$l" = r ] && [ "$R_OK" = 0 ]; then
    RES_STATUS[$key]=SKIP; RES_NOTE[$key]="$R_WHY"; printf '[%s] SKIP: %s\n' "$key" "$R_WHY"; return
  fi
  if [ "$l" = pyspark ] && [ "$PY_OK" = 0 ]; then
    RES_STATUS[$key]=SKIP; RES_NOTE[$key]="$PY_WHY"; printf '[%s] SKIP: %s\n' "$key" "$PY_WHY"; return
  fi
  build_cmd "$l" "$d"
  if [ "$l" = scala ] && [ "$DEPLOY_MODE" = cluster ]; then
    RES_NOTE[$key]="Scala runs in client mode (spark-shell has no cluster mode)"
  fi
  if [ "$DRY_RUN" = 1 ]; then
    echo "[$key]"; show "${CMD[@]}"; RES_STATUS[$key]=DRY; return
  fi
  log "Run $key"
  fs rm "$OUT_URI/$d/$l"   # remove old results of this job
  start="$(date +%s)"
  local pre=()
  command -v timeout >/dev/null 2>&1 && pre=(timeout -k 30 "$JOB_TIMEOUT")
  if [ "$l" = scala ]; then
    "${pre[@]}" "${CMD[@]}" < /dev/null > "$logf" 2>&1 || rc=$?
  else
    "${pre[@]}" "${CMD[@]}" > "$logf" 2>&1 || rc=$?
  fi
  end="$(date +%s)"
  RES_TIME[$key]=$((end - start))

  # The job saves its EVAL lines in HDFS (works in cluster mode too). The log is the fallback.
  text="$(fs cat "$OUT_URI/$d/$l/summary")"
  [ -n "$text" ] || text="$(grep -o -E 'EVAL_(SUMMARY|HOSTS|STATUS) .*' "$logf")"
  RES_SUMMARY[$key]="$(printf '%s\n' "$text" | sed -n 's/^EVAL_SUMMARY //p' | head -n 1)"
  RES_HOSTS[$key]="$(printf '%s\n' "$text" | sed -n 's/^EVAL_HOSTS //p' | head -n 1)"
  app="$(grep -o -E 'application_[0-9]+_[0-9]+' "$logf" | head -n 1)"
  RES_APP[$key]="$app"
  if [ "$rc" = 0 ] && printf '%s\n' "$text" | grep -q '^EVAL_STATUS OK'; then
    RES_STATUS[$key]=PASS
  else
    RES_STATUS[$key]=FAIL
    RES_NOTE[$key]="exit code $rc. See $logf"
    [ "$rc" = 124 ] && RES_NOTE[$key]="timeout after ${JOB_TIMEOUT}s. See $logf"
  fi
  ALL_HOSTS="$ALL_HOSTS,${RES_HOSTS[$key]}"

  echo "  status     : ${RES_STATUS[$key]} in ${RES_TIME[$key]} s"
  echo "  spark hosts: ${RES_HOSTS[$key]:-unknown}  (the driver and the executors)"
  if [ -n "$app" ] && [ "$SPARK_MASTER" = yarn ]; then
    echo "  application: $app"
    echo "  live UI    : http://$MASTER_HOST:$RM_PORT/cluster/app/$app"
    echo "  history UI : http://$MASTER_HOST:$HISTORY_PORT/history/$app/jobs/"
    "$YARN_BIN" application -status "$app" 2>/dev/null \
      | grep -E '^\s*(Queue|State|Final-State|AM Host|Tracking-URL) ' | sed 's/^\s*/  yarn       : /' || true
  fi
}

for d in $DOMAINS; do
  for l in $LANGS; do
    run_job "$l" "$d"
  done
done

# ------------------------------------------------------------------ 3. final table
[ "$DRY_RUN" = 1 ] && { log "Dry run finished. Nothing was run."; exit 0; }

echo
log "Results"
printf '%-12s %-8s %-6s %7s  %-9s %s\n' DOMAIN LANG STATUS "TIME(s)" CLEAN_ROWS NOTE
NPASS=0; NFAIL=0; NSKIP=0
for d in $DOMAINS; do
  for l in $LANGS; do
    key="$l/$d"
    st="${RES_STATUS[$key]:-?}"
    case "$st" in PASS) NPASS=$((NPASS + 1)); c="$C_GRN" ;; FAIL) NFAIL=$((NFAIL + 1)); c="$C_RED" ;; *) NSKIP=$((NSKIP + 1)); c="$C_YEL" ;; esac
    rows="$(summary_value "${RES_SUMMARY[$key]:-}" clean_rows)"
    printf '%-12s %-8s %s%-6s%s %7s  %-9s %s\n' "$d" "$l" "$c" "$st" "$C_OFF" "${RES_TIME[$key]:--}" "${rows:--}" "${RES_NOTE[$key]:-}"
  done
done

# The 3 languages run the same analysis, so their numbers must be equal.
echo
log "Cross-language check (same numbers in every language)"
CMP_BAD=0
for d in $DOMAINS; do
  ref=""; refl=""; n=0; same=1
  for l in $LANGS; do
    s="${RES_SUMMARY[$l/$d]:-}"
    [ "${RES_STATUS[$l/$d]:-}" = PASS ] || continue
    # Drop domain, lang and partitions: they can differ between languages.
    sig="$(printf '%s' "$s" | tr ' ' '\n' | grep -v -E '^(domain|lang|partitions)=' | tr '\n' ' ')"
    n=$((n + 1))
    if [ -z "$ref" ]; then ref="$sig"; refl="$l"; elif [ "$sig" != "$ref" ]; then same=0; echo "  $d: $l differs from $refl"; echo "    $refl: $ref"; echo "    $l: $sig"; fi
  done
  if [ "$n" -lt 2 ]; then echo "  $d: not compared ($n language passed)"
  elif [ "$same" = 1 ]; then echo "  $d: MATCH ($n languages)"
  else CMP_BAD=$((CMP_BAD + 1)); fi
done

# Evidence that the work ran on more than one machine.
echo
log "Distribution evidence"
HOSTS_UNIQ="$(printf '%s' "$ALL_HOSTS" | tr ',' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
NHOSTS="$(printf '%s' "$HOSTS_UNIQ" | wc -w | tr -d ' ')"
echo "  Hosts that ran Spark JVMs in this run: ${HOSTS_UNIQ:-none} ($NHOSTS)"
if [ "$SPARK_MASTER" = yarn ] && [ "$NPASS" -gt 0 ]; then
  if [ "$NHOSTS" -ge 2 ]; then
    echo "  The jobs ran on $NHOSTS different hosts."
  else
    warn "Only $NHOSTS host ran Spark JVMs. This is no proof of distributed work. Check the YARN UI: http://$MASTER_HOST:$RM_PORT/cluster/nodes"
  fi
fi

echo
log "$NPASS passed, $NFAIL failed, $NSKIP skipped. Logs: $RESULT_DIR"
{
  printf 'domain\tlang\tstatus\tseconds\tapplication\thosts\tsummary\n'
  for d in $DOMAINS; do for l in $LANGS; do k="$l/$d"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$d" "$l" "${RES_STATUS[$k]:-?}" "${RES_TIME[$k]:-}" "${RES_APP[$k]:-}" "${RES_HOSTS[$k]:-}" "${RES_SUMMARY[$k]:-}"
  done; done
} > "$RESULT_DIR/summary.tsv"
[ "$NFAIL" = 0 ] && [ "$CMP_BAD" = 0 ] || exit 1
exit 0
