#!/usr/bin/env bash
# Installs MetalLB so Services of type LoadBalancer (the frontend) get a reachable IP on your LAN.
# Run on the control plane (with sudo) or from your workstation after 05-connect-workstation.sh.
#
#   ./04-install-addons.sh
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

start_logging
banner "Install cluster add-ons: MetalLB $METALLB_VERSION"
require_cmd kubectl ""

# ---------------------------------------------------------------------------------------------
step "Check cluster access"
run kc get nodes
ok "Connected"

# ---------------------------------------------------------------------------------------------
step "Install MetalLB"
why "On cloud clusters a LoadBalancer Service gets an IP from the cloud provider. On your own machines nothing provides one, so the Service would stay <pending> forever. MetalLB fills that gap."
conn "kubectl --HTTPS 6443--> API server; nodes pull MetalLB images from quay.io"
run kc apply -f "https://raw.githubusercontent.com/metallb/metallb/$METALLB_VERSION/config/manifests/metallb-native.yaml"
run kc -n metallb-system rollout status deployment/controller --timeout=300s
run kc -n metallb-system rollout status daemonset/speaker --timeout=300s
ok "MetalLB controller and speakers running"

PROXY_MODE=$(kc -n kube-system get configmap kube-proxy -o jsonpath='{.data.config\.conf}' | awk '/^mode:/{print $2}' | tr -d '"')
info "kube-proxy mode: ${PROXY_MODE:-iptables (default)}"
if [[ $PROXY_MODE == ipvs ]]; then
  warn "kube-proxy uses IPVS: MetalLB L2 needs strictARP=true in the kube-proxy ConfigMap (see MetalLB docs)."
fi

# ---------------------------------------------------------------------------------------------
step "Give MetalLB an address pool: $METALLB_IP_RANGE"
why "These IPs must be free, in the same subnet as the nodes, and outside your router's DHCP range: in L2 mode a node answers ARP requests for them, as if they were its own address."
conn "browser --> LoadBalancer IP --(ARP answered by one node's MetalLB speaker)--> that node --> kube-proxy rules --> a backing pod on any node"
POOL=$(cat <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
    - $METALLB_IP_RANGE
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - default-pool
EOF
)
# MetalLB's admission webhook can take a few seconds to accept requests after the pods are Ready.
for attempt in 1 2 3 4 5 6; do
  if kc apply -f - <<< "$POOL"; then break; fi
  (( attempt == 6 )) && fail "MetalLB webhook never became ready."
  info "Webhook not ready yet, retrying in 5s ($attempt/6)"
  sleep 5
done
ok "Address pool configured"

echo
ok "Add-ons installed"
info "Next: ./06-deploy-app.sh from your workstation (after ./05-connect-workstation.sh)."
