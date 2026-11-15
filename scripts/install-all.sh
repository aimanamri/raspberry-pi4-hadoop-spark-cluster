#!/usr/bin/env bash
# Run all master steps in order. Run on the MASTER node, as the hadoop user.
#
#   ./scripts/install-all.sh
#
# Before you run it, run "sudo ./scripts/setup-node.sh" on EVERY Pi (including this one).
# Steps: setup-ssh.sh, install-hadoop.sh, install-spark.sh, start-cluster.sh, verify.sh
# Each step is a separate script. If a step fails, fix the problem and run the script again.
# All scripts can run again safely.
set -euo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for s in setup-ssh install-hadoop install-spark start-cluster verify; do
  echo
  echo "################ $s.sh"
  "$D/$s.sh"
done
