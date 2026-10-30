#!/usr/bin/env bash
# Removes Kubernetes state from THIS node so you can run 02/03 again. Packages stay installed.
# On a worker, first remove it from the cluster (from the control plane / workstation):
#   kubectl drain <node> --ignore-daemonsets --delete-emptydir-data && kubectl delete node <node>
#
#   sudo ./reset-node.sh
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_root
start_logging
banner "Reset Kubernetes on $(hostname)"

warn "This deletes this node's cluster state: certificates, etcd data (on the control plane: the WHOLE cluster), pod network config."
read -r -p "Type the hostname '$(hostname)' to continue: " answer
[[ $answer == "$(hostname)" ]] || fail "Aborted"

step "kubeadm reset"
why "Stops the static control-plane pods, removes /etc/kubernetes and the etcd data, and cleans up kubelet state."
run kubeadm reset -f

step "Remove pod network leftovers"
why "kubeadm reset leaves CNI config, the Flannel/bridge interfaces and iptables rules behind. Stale ones break the next init or join."
run rm -rf /etc/cni/net.d /var/lib/cni
for link in cni0 flannel.1; do ip link show "$link" > /dev/null 2>&1 && run ip link delete "$link"; done
run bash -c 'iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X'
rm -f "$SETUP_DIR/join-command.sh"
if [[ -n ${SUDO_USER:-} ]]; then rm -f "$(getent passwd "$SUDO_USER" | cut -d: -f6)/.kube/config"; fi

echo
ok "$(hostname) reset. Run 02-init-control-plane.sh or 03-join-worker.sh again."
