#!/usr/bin/env bash
# Prepare one Raspberry Pi. Run this on EVERY Pi, with sudo.   (README Parts 1.4 to 1.7 and Part 2)
#
#   sudo ./scripts/setup-node.sh [--hostname NAME] [--dry-run]
#
# What it does:
#   1. Detects the OS (Raspberry Pi OS, Ubuntu or Debian) and checks that it is 64-bit.
#   2. Updates the packages and installs curl, rsync, zip, unzip and ssh.
#   3. Expands the root file system (Raspberry Pi OS only).
#   4. Sets the host name and the /etc/hosts entries for all nodes.
#   5. Creates the hadoop user.
#   6. Installs Java 17: apt if the OS has the package, if not SDKMAN.
# The script does NOT set a static IP address. Set it on your router (see README 1.5).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NODE_NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --hostname) NODE_NAME="${2:?--hostname needs a value}"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  sed -n '2,15p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

load_env
[ "$DRY_RUN" = "1" ] || require_root
detect_os
require_arch
NODE_NAME="${NODE_NAME:-$(hostname)}"
node_exists "$NODE_NAME" || die "This node is called '$NODE_NAME'. It is not in NODES ($NODES). Run with --hostname <name> or change NODES in scripts/.env."
log "This node: $NODE_NAME ($(node_ip "$NODE_NAME")). Master: $MASTER_HOST."

# ------------------------------------------------------------------ 1. packages
log "Update packages"
export DEBIAN_FRONTEND=noninteractive
run apt-get update -y
if [ "${SKIP_UPGRADE:-0}" != "1" ]; then run apt-get upgrade -y; fi
run apt-get install -y curl wget rsync zip unzip openssh-server ca-certificates

# ------------------------------------------------------------------ 2. root file system
if [ "$OS_ID" = "raspios" ] && command -v raspi-config >/dev/null 2>&1; then
  log "Expand the root file system"
  run raspi-config --expand-rootfs || warn "raspi-config could not expand the file system. Continue."
  NEED_REBOOT=1
fi

# ------------------------------------------------------------------ 3. host name and /etc/hosts
log "Set the host name to $NODE_NAME"
if [ "$(hostname)" != "$NODE_NAME" ]; then
  if command -v hostnamectl >/dev/null 2>&1; then run hostnamectl set-hostname "$NODE_NAME"; else run hostname "$NODE_NAME"; fi
  NEED_REBOOT=1
fi

log "Write the node addresses to /etc/hosts"
# Debian and Ubuntu map the own host name to 127.0.1.1. Hadoop then listens on the loopback address only. Remove that line.
if [ "$DRY_RUN" != "1" ]; then
  # Write in place (cat >) because /etc/hosts can be a mounted file
  tmp_hosts="$(mktemp)"
  sed "/^127\.0\.1\.1[[:space:]]/d" /etc/hosts > "$tmp_hosts"
  cat "$tmp_hosts" > /etc/hosts
  rm -f "$tmp_hosts"
  {
    for n in $(all_nodes); do printf '%s\t%s\n' "$(node_ip "$n")" "$n"; done
  } | ensure_block /etc/hosts nodes
else
  echo "[dry-run] write the node list to /etc/hosts"
fi

# ------------------------------------------------------------------ 4. hadoop user
if id "$HADOOP_USER" >/dev/null 2>&1; then
  ok "User '$HADOOP_USER' exists"
else
  log "Create the user '$HADOOP_USER'"
  run adduser --disabled-password --gecos "" "$HADOOP_USER"
  run usermod -aG sudo "$HADOOP_USER"
  if [ "$DRY_RUN" != "1" ] && [ -t 0 ]; then
    echo "Set a password for '$HADOOP_USER'. You need it once for ssh-copy-id."
    passwd "$HADOOP_USER"
  else
    warn "Set a password with: sudo passwd $HADOOP_USER"
  fi
fi

# ------------------------------------------------------------------ 5. Java
APT_PKG="openjdk-$JAVA_VERSION-jdk"
apt_has_java() {
  local c; c="$(apt-cache policy "$APT_PKG" 2>/dev/null | awk '/Candidate:/{print $2}')"
  [ -n "$c" ] && [ "$c" != "(none)" ]
}

install_java_apt() {
  log "Install $APT_PKG with apt"
  run apt-get install -y "$APT_PKG"
  JAVA_HOME_PATH="/usr/lib/jvm/java-$JAVA_VERSION-openjdk-$(dpkg --print-architecture)"
  [ "$DRY_RUN" = "1" ] || [ -x "$JAVA_HOME_PATH/bin/java" ] || die "Expected Java at $JAVA_HOME_PATH but did not find it. Check with: readlink -f \$(which java)"
}

install_java_sdkman() {
  log "Install Java $JAVA_VERSION with SDKMAN (user $HADOOP_USER)"
  local sdk="$HADOOP_USER_HOME/.sdkman"
  if [ ! -d "$sdk" ]; then
    local inst; inst="$(mktemp)"
    run curl -fsSL https://get.sdkman.io -o "$inst"
    run chmod 644 "$inst"
    run su - "$HADOOP_USER" -c "bash '$inst'"
    rm -f "$inst"
  fi
  # Answer SDKMAN questions with yes, so that the script does not stop
  if [ "$DRY_RUN" != "1" ] && [ -f "$sdk/etc/config" ]; then
    sed -i 's/^sdkman_auto_answer=.*/sdkman_auto_answer=true/' "$sdk/etc/config"
  fi
  local ident="${SDKMAN_JAVA_IDENTIFIER:-}"
  if [ -z "$ident" ] && [ "$DRY_RUN" != "1" ]; then
    ident="$(su - "$HADOOP_USER" -c "source '$sdk/bin/sdkman-init.sh' && sdk list java" 2>/dev/null \
      | awk -F'|' 'NF>=4 {gsub(/[ \t]/, "", $4); print $4}' | grep -E "^${JAVA_VERSION}\.[^ ]*-tem$" | sort -uV | tail -1 || true)"
    [ -n "$ident" ] || die "Could not find a Temurin $JAVA_VERSION build in 'sdk list java'. Set SDKMAN_JAVA_IDENTIFIER in scripts/.env."
    log "Use SDKMAN identifier: $ident"
  fi
  run su - "$HADOOP_USER" -c "source '$sdk/bin/sdkman-init.sh' && sdk install java '$ident' && sdk default java '$ident'"
  JAVA_HOME_PATH="$sdk/candidates/java/current"
}

case "$JAVA_METHOD" in
  apt)    install_java_apt ;;
  sdkman) install_java_sdkman ;;
  auto)
    if apt_has_java; then install_java_apt
    else
      warn "apt has no $APT_PKG on $OS_PRETTY. Use SDKMAN instead."
      install_java_sdkman
    fi ;;
  *) die "JAVA_METHOD must be auto, apt or sdkman." ;;
esac

if [ "$DRY_RUN" != "1" ]; then
  jv="$("$JAVA_HOME_PATH/bin/java" -version 2>&1 | head -1)"
  case "$jv" in
    *"\"$JAVA_VERSION"*) ok "Java: $jv" ;;
    *) die "Java at $JAVA_HOME_PATH reports: $jv (expected version $JAVA_VERSION)." ;;
  esac
  write_env_file
  ok "JAVA_HOME=$JAVA_HOME_PATH (saved in $ENV_SH)"
fi
check_python

# ------------------------------------------------------------------ done
echo
ok "Node $NODE_NAME is ready."
[ "${NEED_REBOOT:-0}" = "1" ] && warn "Restart this Pi now:  sudo reboot"
if [ "$NODE_NAME" = "$MASTER_HOST" ]; then
  echo "Next, on this master node, as the $HADOOP_USER user:"
  echo "  sudo -iu $HADOOP_USER"
  echo "  git clone <this repo> && cd raspberry-pi4-hadoop-spark-cluster   (or copy the folder)"
  echo "  ./scripts/install-all.sh        (after setup-node.sh finished on ALL Pis)"
else
  echo "Nothing more to do on this worker node. Go back to the master node."
fi
