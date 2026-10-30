#!/usr/bin/env bash
# Run on each WORKER node as root, after 01-prepare-node.sh --role worker. Joins the cluster.
#
#   sudo ./03-join-worker.sh [path/to/join-command.sh]    (default: ./join-command.sh)
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

JOIN_FILE="${1:-$SETUP_DIR/join-command.sh}"

require_root
start_logging
banner "Join $(hostname) to the cluster as a worker"

# ---------------------------------------------------------------------------------------------
step "Pre-checks"
require_cmd kubeadm "Run 01-prepare-node.sh --role worker first."
[[ -f /etc/kubernetes/kubelet.conf ]] && fail "This node already belongs to a cluster. To start over: sudo ./reset-node.sh"
[[ -r $JOIN_FILE ]] || fail "No join command at $JOIN_FILE. Run 02-init-control-plane.sh, then '00-copy-to-nodes.sh --join' from your workstation."
JOIN_CMD=$(grep '^kubeadm join' "$JOIN_FILE") || fail "$JOIN_FILE doesn't contain a 'kubeadm join' line."
API=$(awk '{print $3}' <<< "$JOIN_CMD")
ok "Join command found for API server $API"

# ---------------------------------------------------------------------------------------------
step "Check this node can reach the API server at $API"
why "Joining is just this node's kubelet making HTTPS calls to the API server. If that port is blocked, the join hangs, so test it first."
conn "$(hostname) --HTTPS tcp/6443--> $API (kube-apiserver)"
if [[ $(curl -sk --max-time 5 "https://$API/livez") == ok ]]; then
  ok "API server answered /livez = ok"
else
  fail "Can't reach https://$API. Check the control plane is up and that tcp/6443 is open between the nodes."
fi

# ---------------------------------------------------------------------------------------------
step "kubeadm join"
why "kubeadm downloads the cluster info, checks it against the CA hash (so it can't be tricked by an impostor), then starts kubelet with the bootstrap token."
conn "kubelet uses the token to request a client certificate (TLS bootstrap). The control plane signs it automatically, and from then on kubelet authenticates with /var/lib/kubelet/pki/kubelet-client-current.pem."
# Not using run(): the command contains the bootstrap token, which must stay out of the log.
info "\$ kubeadm join $API --token ****** --discovery-token-ca-cert-hash sha256:******"
bash -c "$JOIN_CMD"
ok "Joined"

# ---------------------------------------------------------------------------------------------
step "Confirm kubelet is running"
run systemctl is-active kubelet
conn "Flannel starts on this node within ~30s and gives it a pod subnet. Then the node turns Ready and the scheduler can place pods here."

echo
ok "$(hostname) joined the cluster"
info "Check from the control plane or your workstation:  kubectl get nodes -o wide"
