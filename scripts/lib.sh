#!/usr/bin/env bash
# Shared helpers for the cluster scripts. Source this file. Do not run it.
#   source "$(dirname "$0")/lib.sh"
# Works with bash 4 and later (Raspberry Pi OS and Ubuntu).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ------------------------------------------------------------------ output
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_OFF=""
fi
log()  { printf '%s==>%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s OK%s  %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%sWARN%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%sFAIL%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

# DRY_RUN=1 prints the commands and does not run them.
DRY_RUN="${DRY_RUN:-0}"
run() {
  if [ "$DRY_RUN" = "1" ]; then printf '[dry-run] %s\n' "$*"; return 0; fi
  "$@"
}

# ------------------------------------------------------------------ settings
load_env() {
  if [ -f "$SCRIPT_DIR/.env" ]; then
    ENV_FILE="$SCRIPT_DIR/.env"
  else
    ENV_FILE="$SCRIPT_DIR/.env.example"
    warn "scripts/.env not found. Using the default values in scripts/.env.example."
  fi
  # shellcheck disable=SC1090
  . "$ENV_FILE"

  : "${NODES:?NODES is not set in $ENV_FILE}"
  : "${MASTER_HOST:?MASTER_HOST is not set in $ENV_FILE}"
  HADOOP_USER="${HADOOP_USER:-hadoop}"
  HADOOP_USER_HOME="${HADOOP_USER_HOME:-/home/$HADOOP_USER}"
  HADOOP_VERSION="${HADOOP_VERSION:-3.5.0}"
  SPARK_VERSION="${SPARK_VERSION:-4.3.0}"
  JAVA_VERSION="${JAVA_VERSION:-17}"
  JAVA_METHOD="${JAVA_METHOD:-auto}"
  HDFS_PORT="${HDFS_PORT:-9000}"
  HDFS_REPLICATION="${HDFS_REPLICATION:-1}"
  HDFS_DATA_DIR="${HDFS_DATA_DIR:-$HADOOP_USER_HOME/hdfs}"
  HADOOP_DIR="$HADOOP_USER_HOME/hadoop-$HADOOP_VERSION"
  SPARK_DIR="$HADOOP_USER_HOME/spark-$SPARK_VERSION"
  ENV_SH="$HADOOP_USER_HOME/.pi-cluster-env.sh"

  node_exists "$MASTER_HOST" || die "MASTER_HOST '$MASTER_HOST' is not in NODES ($NODES)."
  WORKER_HOSTS=""
  local n
  for n in $(all_nodes); do
    [ "$n" = "$MASTER_HOST" ] || WORKER_HOSTS="$WORKER_HOSTS $n"
  done
  WORKER_HOSTS="${WORKER_HOSTS# }"
}

all_nodes() { local e; for e in $NODES; do printf '%s ' "${e%%=*}"; done; }
node_ip()   { local e; for e in $NODES; do [ "${e%%=*}" = "$1" ] && { printf '%s' "${e#*=}"; return 0; }; done; return 1; }
node_exists() { node_ip "$1" >/dev/null; }

# ------------------------------------------------------------------ OS and CPU
# Sets OS_ID (ubuntu | raspios | debian), OS_CODENAME and OS_PRETTY.
detect_os() {
  [ "$(uname -s)" = "Linux" ] || die "These scripts run on Linux (Raspberry Pi OS or Ubuntu). This OS is $(uname -s)."
  [ -r /etc/os-release ] || die "Cannot read /etc/os-release."
  local ID="" ID_LIKE="" VERSION_CODENAME="" PRETTY_NAME=""
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_CODENAME="${VERSION_CODENAME:-unknown}"
  OS_PRETTY="${PRETTY_NAME:-$ID}"
  case "$ID" in
    ubuntu) OS_ID=ubuntu ;;
    raspbian) OS_ID=raspios ;;
    debian)
      if [ -f /etc/rpi-issue ] || grep -qi 'raspberry pi' /proc/device-tree/model 2>/dev/null; then
        OS_ID=raspios
      else
        OS_ID=debian
      fi ;;
    *)
      case " $ID_LIKE " in
        *" ubuntu "*) OS_ID=ubuntu ;;
        *" debian "*) OS_ID=debian ;;
        *) die "Unsupported OS '$ID'. Use Raspberry Pi OS or Ubuntu Server (64-bit)." ;;
      esac ;;
  esac
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found. These scripts need a Debian-based OS."
  log "OS: $OS_PRETTY ($OS_ID, $OS_CODENAME)"
}

require_arch() {
  local m; m="$(uname -m)"
  [ "$m" = "aarch64" ] || [ "$m" = "x86_64" ] || die "CPU is '$m'. Use a 64-bit OS (aarch64). The guide does not support 32-bit."
  [ "$m" = "aarch64" ] || warn "CPU is '$m', not aarch64. The Hadoop aarch64 build will not run here. Use this only for tests."
}

# Hadoop tarball name for this CPU
hadoop_tarball() {
  if [ "$(uname -m)" = "aarch64" ]; then printf 'hadoop-%s-aarch64.tar.gz' "$HADOOP_VERSION"; else printf 'hadoop-%s.tar.gz' "$HADOOP_VERSION"; fi
}

check_python() {
  if command -v python3 >/dev/null 2>&1; then
    local v; v="$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
    if python3 -c 'import sys;sys.exit(0 if sys.version_info>=(3,11) else 1)'; then
      ok "Python $v (PySpark in Spark $SPARK_VERSION needs 3.11 or later)"
    else
      warn "Python $v is too old for PySpark in Spark $SPARK_VERSION (needs 3.11 or later). spark-shell and spark-submit with Scala or Java still work."
    fi
  else
    warn "python3 not found. PySpark needs Python 3.11 or later."
  fi
}

# ------------------------------------------------------------------ users
require_root() { [ "$(id -u)" -eq 0 ] || die "Run this script with sudo."; }
require_user() {
  [ "$(id -un)" = "$HADOOP_USER" ] || die "Run this script as the '$HADOOP_USER' user (sudo -iu $HADOOP_USER)."
}
require_master() {
  local me; me="$(hostname)"
  [ "$me" = "$MASTER_HOST" ] || die "Run this script on the master node '$MASTER_HOST'. This node is '$me'."
}

# ------------------------------------------------------------------ files
# ensure_block FILE NAME  (content on stdin)
# Writes a block between marker lines. A second run replaces the same block.
ensure_block() {
  local file="$1" name="$2" begin end tmp
  begin="# >>> pi-cluster:$name >>>"
  end="# <<< pi-cluster:$name <<<"
  tmp="$(mktemp)"
  touch "$file"
  awk -v b="$begin" -v e="$end" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$file" > "$tmp"
  { cat "$tmp"; printf '%s\n' "$begin"; cat; printf '%s\n' "$end"; } > "$file"
  rm -f "$tmp"
}

# download URL... FILE : tries each URL in turn
download_any() {
  local dest="$1"; shift
  local u
  for u in "$@"; do
    log "Download $u"
    if curl -fL --retry 3 --connect-timeout 20 -o "$dest" "$u"; then return 0; fi
    warn "Could not download from $u"
  done
  return 1
}

# verify_sha512 FILE SHA_FILE : reads the first 128-hex-digit string in SHA_FILE
verify_sha512() {
  local file="$1" shafile="$2" want got
  want="$(tr -d ' \r\n' < "$shafile" | grep -o '[0-9A-Fa-f]\{128\}' | head -1 | tr 'A-F' 'a-f')"
  [ -n "$want" ] || { warn "Could not read the checksum in $shafile."; return 2; }
  got="$(sha512sum "$file" | awk '{print $1}')"
  [ "$want" = "$got" ] || die "Checksum of $(basename "$file") does not match. Delete the file and run the script again."
  ok "Checksum OK: $(basename "$file")"
}

# fetch_apache BASEURL ARCHIVEURL PATH_UNDER_BASE DEST_DIR  ->  downloads file and checks it
fetch_apache() {
  local base="$1" archive="$2" path="$3" dest="$4" name
  name="$(basename "$path")"
  mkdir -p "$dest"
  if [ -f "$dest/$name" ]; then
    log "Found $dest/$name. Using the existing file."
  else
    download_any "$dest/$name" "$base/$path" "$archive/$path" || die "Download of $name failed."
  fi
  if download_any "$dest/$name.sha512" "$base/$path.sha512" "$archive/$path.sha512" >/dev/null 2>&1; then
    verify_sha512 "$dest/$name" "$dest/$name.sha512"
  else
    warn "No checksum file found for $name. Skipping the check."
  fi
}

# ------------------------------------------------------------------ environment file for the hadoop user
# Writes ~/.pi-cluster-env.sh. Every script calls this, so it always matches what is installed.
write_env_file() {
  local jh="${JAVA_HOME_PATH:-}"
  if [ -z "$jh" ] && [ -f "$ENV_SH" ]; then
    jh="$(sed -n 's/^export JAVA_HOME=//p' "$ENV_SH" | head -1)"
  fi
  [ -n "$jh" ] || die "JAVA_HOME is not known. Run scripts/setup-node.sh first."
  {
    echo "# Written by scripts/*.sh. Do not edit. Run the scripts again to change it."
    echo "export JAVA_HOME=$jh"
    echo 'export PATH=$JAVA_HOME/bin:$PATH'
    if [ -d "$HADOOP_DIR" ]; then
      cat <<EOF
export HADOOP_HOME=$HADOOP_DIR
export HADOOP_INSTALL=\$HADOOP_HOME
export HADOOP_MAPRED_HOME=\$HADOOP_HOME
export HADOOP_COMMON_HOME=\$HADOOP_HOME
export HADOOP_HDFS_HOME=\$HADOOP_HOME
export YARN_HOME=\$HADOOP_HOME
export HADOOP_COMMON_LIB_NATIVE_DIR=\$HADOOP_HOME/lib/native
export HADOOP_CONF_DIR=\$HADOOP_HOME/etc/hadoop
export HADOOP_OPTS="-Djava.library.path=\$HADOOP_HOME/lib/native"
export PATH=\$PATH:\$HADOOP_HOME/bin:\$HADOOP_HOME/sbin
EOF
    fi
    if [ -d "$SPARK_DIR" ]; then
      cat <<EOF
export SPARK_HOME=$SPARK_DIR
export PATH=\$PATH:\$SPARK_HOME/bin:\$SPARK_HOME/sbin
export LD_LIBRARY_PATH=\${HADOOP_HOME:+\$HADOOP_HOME/lib/native:}\${LD_LIBRARY_PATH:-}
export PYSPARK_PYTHON=python3
EOF
    fi
  } > "$ENV_SH"
  # Interactive shells read .bashrc and login shells read .profile. Both load the file.
  local rc line='[ -f "$HOME/.pi-cluster-env.sh" ] && . "$HOME/.pi-cluster-env.sh"'
  for rc in "$HADOOP_USER_HOME/.bashrc" "$HADOOP_USER_HOME/.profile"; do
    printf '%s\n' "$line" | ensure_block "$rc" env
  done
  if [ "$(id -u)" -eq 0 ]; then
    chown "$HADOOP_USER:$HADOOP_USER" "$ENV_SH" "$HADOOP_USER_HOME/.bashrc" "$HADOOP_USER_HOME/.profile" 2>/dev/null || true
  fi
}

# Load the environment file (JAVA_HOME, HADOOP_HOME, SPARK_HOME) into this shell
load_cluster_env() {
  [ -f "$ENV_SH" ] || die "$ENV_SH not found. Run scripts/setup-node.sh first."
  # shellcheck disable=SC1090
  . "$ENV_SH"
}

# ssh to a node without prompts
node_ssh() { local n="$1"; shift; ssh -o BatchMode=yes -o ConnectTimeout=10 "$n" "$@"; }
