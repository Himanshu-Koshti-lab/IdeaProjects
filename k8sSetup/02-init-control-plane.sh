#!/usr/bin/env bash
# Run on the CONTROL-PLANE node as root, after 01-prepare-node.sh. Creates the cluster, installs
# pod networking (Flannel) and writes the join command for workers.
#
#   sudo ./02-init-control-plane.sh                 # control plane runs only system pods
#   sudo ./02-init-control-plane.sh --single-node   # also run app pods here (no workers)
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SINGLE_NODE=false
[[ "${1:-}" == "--single-node" ]] && SINGLE_NODE=true

require_root
start_logging
banner "Initialise Kubernetes control plane on $(hostname)"

API_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-$CONTROL_PLANE_IP}:6443"

# ---------------------------------------------------------------------------------------------
step "Pre-checks"
require_cmd kubeadm "Run 01-prepare-node.sh --role control-plane first."
[[ -f /etc/kubernetes/admin.conf ]] && fail "This node already runs a control plane. To start over: sudo ./reset-node.sh"
ip -4 -o addr | grep -qw "$CONTROL_PLANE_IP" || fail "CONTROL_PLANE_IP=$CONTROL_PLANE_IP is not an address of this machine (check cluster.env)."
info "API endpoint: https://$API_ENDPOINT | pod CIDR $POD_CIDR | service CIDR $SERVICE_CIDR"
ok "Ready to initialise"

# ---------------------------------------------------------------------------------------------
step "Pull control-plane images"
why "Downloading first makes problems with registry access show up now, with a clear error, instead of as a timeout in the middle of init."
conn "containerd --HTTPS 443--> registry.k8s.io"
run kubeadm config images pull --kubernetes-version "$(kubeadm version -o short)"
ok "Images pulled"

# ---------------------------------------------------------------------------------------------
step "kubeadm init"
why "This creates the cluster: a certificate authority + TLS certs (/etc/kubernetes/pki), static pods for etcd, kube-apiserver, controller-manager and scheduler (/etc/kubernetes/manifests, started by kubelet), then CoreDNS and kube-proxy."
conn "kube-apiserver listens on https://$API_ENDPOINT. Every component talks ONLY to it: kubelets, controllers, scheduler, kubectl. Only the API server talks to etcd (127.0.0.1:2379)."
INIT_ARGS=(
  --apiserver-advertise-address "$CONTROL_PLANE_IP"
  --control-plane-endpoint "$API_ENDPOINT"
  --pod-network-cidr "$POD_CIDR"
  --service-cidr "$SERVICE_CIDR"
  --kubernetes-version "$(kubeadm version -o short)"
)
[[ -n $CONTROL_PLANE_ENDPOINT ]] && INIT_ARGS+=(--apiserver-cert-extra-sans "$CONTROL_PLANE_ENDPOINT,$CONTROL_PLANE_IP")
# kubeadm prints its own join command at the end; we write ours to a file instead (step 6).
run kubeadm init "${INIT_ARGS[@]}" | sed '/kubeadm join/,$d'
ok "Control plane is up"

# ---------------------------------------------------------------------------------------------
step "Set up kubectl on this machine"
why "/etc/kubernetes/admin.conf holds the cluster CA and an admin client certificate. kubectl uses the CA to trust the API server and the certificate to prove who it is."
if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
  USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  mkdir -p "$USER_HOME/.kube"
  rename_kubeconfig < /etc/kubernetes/admin.conf > "$USER_HOME/.kube/config"
  chmod 600 "$USER_HOME/.kube/config"
  chown -R "$SUDO_USER:" "$USER_HOME/.kube"
  ok "$SUDO_USER can now run kubectl here (context '$CLUSTER_NAME' in $USER_HOME/.kube/config)"
else
  info "Running as root directly: use 'export KUBECONFIG=/etc/kubernetes/admin.conf'"
fi

# ---------------------------------------------------------------------------------------------
step "Install pod network: Flannel ($FLANNEL_VERSION)"
why "Until a CNI plugin is installed, nodes are NotReady and CoreDNS stays Pending: pods have no IPs and no way to reach other nodes."
conn "Each node gets a /24 out of $POD_CIDR. Pod traffic to another node is wrapped in VXLAN (UDP 8472) and sent to that node's IP, where Flannel unwraps it into the target pod."
if [[ $FLANNEL_VERSION == latest ]]; then
  FLANNEL_URL=https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
else
  FLANNEL_URL=https://github.com/flannel-io/flannel/releases/download/$FLANNEL_VERSION/kube-flannel.yml
fi
FLANNEL_FILE=$(mktemp --suffix=.yaml)
run curl -fsSL -o "$FLANNEL_FILE" "$FLANNEL_URL"
# Flannel's manifest hardcodes 10.244.0.0/16; keep it in sync with POD_CIDR.
sed -i "s#10.244.0.0/16#$POD_CIDR#" "$FLANNEL_FILE"
run kc apply -f "$FLANNEL_FILE"
rm -f "$FLANNEL_FILE"
run kc -n kube-flannel rollout status daemonset/kube-flannel-ds --timeout=300s
run kc wait --for=condition=Ready node --all --timeout=300s
run kc -n kube-system rollout status deployment/coredns --timeout=300s
ok "Pod network ready, CoreDNS running"

# ---------------------------------------------------------------------------------------------
if $SINGLE_NODE; then
  step "Allow app pods on the control plane (single-node mode)"
  why "kubeadm taints the control plane so normal workloads stay off it. With no workers, remove the taint or app pods would stay Pending forever."
  run kc taint nodes --all node-role.kubernetes.io/control-plane- || true
  ok "Control plane accepts app pods"
fi

# ---------------------------------------------------------------------------------------------
step "Write the worker join command"
why "A worker needs three things to join: the API server address, a bootstrap token (lets it in for 24h) and the CA certificate hash (so it can verify it's talking to THIS cluster, not an impostor)."
conn "worker kubelet --HTTPS--> https://$API_ENDPOINT (token auth) --> requests its own client certificate --> auto-approved --> from then on uses that certificate."
JOIN_FILE="$SETUP_DIR/join-command.sh"
{
  echo '#!/usr/bin/env bash'
  echo '# Secret: contains a bootstrap token valid for 24h. Regenerate: sudo kubeadm token create --print-join-command'
  kubeadm token create --print-join-command --ttl 24h
} > "$JOIN_FILE"
chmod 600 "$JOIN_FILE"
[[ -n ${SUDO_USER:-} ]] && chown "$SUDO_USER:" "$JOIN_FILE"
ok "Saved to $JOIN_FILE (token not printed: it's a secret)"

# ---------------------------------------------------------------------------------------------
step "Cluster status"
run kc get nodes -o wide
run kc get pods -A

echo
ok "Control plane '$(hostname)' initialised"
if [[ -n $WORKER_IPS ]] && ! $SINGLE_NODE; then
  info "Next: from your workstation run  ./00-copy-to-nodes.sh --join   then on each worker:  sudo ./03-join-worker.sh"
fi
info "Then: ./04-install-addons.sh (here or from your workstation) and ./05-connect-workstation.sh on your workstation."
