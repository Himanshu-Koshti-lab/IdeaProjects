#!/usr/bin/env bash
# Health check for the cluster and the app. Run on the control plane or your workstation, any time.
#
#   ./verify-cluster.sh
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

start_logging
banner "Verify $CLUSTER_NAME"
require_cmd kubectl ""
PROBLEMS=0
problem() { warn "$*"; PROBLEMS=$((PROBLEMS + 1)); }

step "API server"
conn "kubectl --HTTPS 6443--> kube-apiserver"
[[ $(kc get --raw /readyz) == ok ]] && ok "API server ready" || problem "API server not ready"

step "Nodes"
why "Each node must be Ready: kubelet is reporting in and the pod network is up on it."
run kc get nodes -o wide
NOT_READY=$(kc get nodes --no-headers | awk '$2 != "Ready" {print $1}')
[[ -z $NOT_READY ]] && ok "All nodes Ready" || problem "Not ready: $NOT_READY (on that node: journalctl -u kubelet -e)"

step "System pods"
why "etcd, apiserver, scheduler, controller-manager, CoreDNS, kube-proxy and Flannel must all be running."
BAD=$(kc get pods -A --no-headers | awk '$4 != "Running" && $4 != "Completed" {print $1 "/" $2 " (" $4 ")"}')
[[ -z $BAD ]] && ok "All pods Running" || problem "Unhealthy pods: $BAD"

step "Cluster DNS"
why "Pods find each other by Service name (the frontend reaches 'nomanualcode-backend' this way), so CoreDNS must answer."
conn "test pod --UDP 53--> kube-dns Service --> CoreDNS pod"
if kc run dns-check --image=busybox:1.36 --restart=Never --rm -i --quiet --timeout=60s \
    -- nslookup kubernetes.default.svc.cluster.local > /dev/null 2>&1; then
  ok "kubernetes.default.svc.cluster.local resolves"
else
  problem "DNS lookup failed from inside a pod"
fi

step "MetalLB"
if kc get namespace metallb-system > /dev/null 2>&1; then
  run kc -n metallb-system get ipaddresspools.metallb.io
  ok "MetalLB installed"
else
  problem "MetalLB not installed (./04-install-addons.sh): LoadBalancer Services will stay <pending>"
fi

step "App ($APP_NAMESPACE)"
if kc get namespace "$APP_NAMESPACE" > /dev/null 2>&1; then
  run kc -n "$APP_NAMESPACE" get pods,services
  IP=$(kc -n "$APP_NAMESPACE" get service nomanualcode-frontend -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2> /dev/null || true)
  if [[ -n $IP ]] && curl -sf --max-time 5 "http://$IP/api/persons" > /dev/null; then
    ok "http://$IP/api/persons answers (frontend --> backend path works)"
  else
    problem "App not reachable from here at http://${IP:-<no ip>}/api/persons"
  fi
else
  info "App not deployed yet (./06-deploy-app.sh)"
fi

echo
(( PROBLEMS == 0 )) && ok "Everything healthy" || fail "$PROBLEMS problem(s) found, see WARN lines above"
