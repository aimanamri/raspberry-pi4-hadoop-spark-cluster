#!/usr/bin/env bash
# Set up password-less SSH. Run this on the MASTER node, as the hadoop user.   (README 1.8)
#
#   ./scripts/setup-ssh.sh [--dry-run]
#
# What it does:
#   1. Creates ~/.ssh with the right permissions and an RSA key pair (no password).
#   2. Writes an SSH alias for each node (Host pi1, pi2, pi3 ...).
#   3. Copies the public key to every node with ssh-copy-id. You type the password of
#      the hadoop user once for each node.
#   4. Tests the connection to every node.
# Run setup-node.sh on all Pis first, and make sure that the Pis are on and reachable.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

load_env
require_user
require_master

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [ -f "$HOME/.ssh/id_rsa" ]; then
  ok "SSH key exists: ~/.ssh/id_rsa"
else
  log "Create an SSH key pair (no password)"
  run ssh-keygen -t rsa -b 4096 -N "" -f "$HOME/.ssh/id_rsa"
fi

log "Write the SSH aliases to ~/.ssh/config"
{
  for n in $(all_nodes); do
    printf 'Host %s\n  User %s\n  Hostname %s\n  StrictHostKeyChecking accept-new\n\n' "$n" "$HADOOP_USER" "$(node_ip "$n")"
  done
} | ensure_block "$HOME/.ssh/config" nodes
chmod 600 "$HOME/.ssh/config"

FAILED=""
for n in $(all_nodes); do
  if node_ssh "$n" true 2>/dev/null; then
    ok "$n: SSH works without a password"
    continue
  fi
  log "Copy the key to $n (enter the password of '$HADOOP_USER' on $n)"
  if run ssh-copy-id -o StrictHostKeyChecking=accept-new "$n" && { [ "$DRY_RUN" = "1" ] || node_ssh "$n" true; }; then
    ok "$n: SSH works without a password"
  else
    warn "$n: SSH does not work yet"
    FAILED="$FAILED $n"
  fi
done

[ -z "$FAILED" ] || die "Could not connect to:$FAILED. Check that the Pi is on, the IP address in scripts/.env is right, and the password is right."
ok "Password-less SSH works from $MASTER_HOST to all nodes."
