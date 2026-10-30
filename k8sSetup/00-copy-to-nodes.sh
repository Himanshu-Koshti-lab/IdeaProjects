#!/usr/bin/env bash
# Run on your WORKSTATION. Copies this k8sSetup folder to every node over SSH.
#
#   ./00-copy-to-nodes.sh           # copy scripts + cluster.env to all nodes (before step 01)
#   ./00-copy-to-nodes.sh --join    # relay join-command.sh from the control plane to workers (after step 02)
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MODE=copy
[[ "${1:-}" == "--join" ]] && MODE="join"

start_logging
banner "Copy k8sSetup to nodes (mode: $MODE)"
require_cmd ssh "Git Bash, macOS and Linux include it."
require_cmd tar ""

conn "workstation --SSH tcp/22--> $SSH_USER@<node>. Use SSH keys (ssh-copy-id $SSH_USER@<node>) to avoid password prompts."

if [[ $MODE == copy ]]; then
  for node in $(all_node_ips); do
    step "Copy k8sSetup to $SSH_USER@$node:~/k8sSetup"
    why "Every node runs 01-prepare-node.sh locally and needs the same cluster.env, so all nodes agree on versions and network ranges."
    # tar over ssh: one connection, keeps the executable bit, skips local logs and secrets.
    tar -C "$SETUP_DIR/.." --exclude='k8sSetup/logs' --exclude='k8sSetup/join-command.sh' -cf - k8sSetup \
      | ssh "$SSH_USER@$node" 'tar -xf - && chmod +x ~/k8sSetup/*.sh'
    ok "Copied to $node"
  done
  info "Next, on EACH node:  cd ~/k8sSetup && sudo ./01-prepare-node.sh --role control-plane|worker"
else
  step "Relay join command from control plane $CONTROL_PLANE_IP to workers"
  why "Workers need the bootstrap token and CA hash that kubeadm generated on the control plane. It's a secret, so it's streamed node-to-node with mode 600 and never printed."
  for node in $WORKER_IPS; do
    ssh "$SSH_USER@$CONTROL_PLANE_IP" 'cat ~/k8sSetup/join-command.sh' \
      | ssh "$SSH_USER@$node" 'umask 077 && cat > ~/k8sSetup/join-command.sh'
    ok "join-command.sh delivered to $node"
  done
  info "Next, on EACH worker:  cd ~/k8sSetup && sudo ./03-join-worker.sh"
fi
