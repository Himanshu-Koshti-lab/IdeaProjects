#!/usr/bin/env bash
# Run on your WORKSTATION after ../build-images.sh --save. Ships the image artifacts to every node
# (no registry needed), then deploys the app with kubectl.
#
#   ./06-deploy-app.sh [artifacts-dir]     (default: ../artifacts)
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ARTIFACTS="${1:-$SETUP_DIR/../artifacts}"

start_logging
banner "Deploy nomanualcode to $CLUSTER_NAME (namespace $APP_NAMESPACE)"
require_cmd ssh ""
require_cmd kubectl ""

# ---------------------------------------------------------------------------------------------
step "Find image artifacts"
latest() { ls -t "$ARTIFACTS"/"$1"-*.tar.gz 2> /dev/null | head -1; }
BACKEND_TAR=$(latest nomanualcode-backend)
FRONTEND_TAR=$(latest nomanualcode-frontend)
[[ -n $BACKEND_TAR && -n $FRONTEND_TAR && -d $ARTIFACTS/k8s ]] \
  || fail "No artifacts in $ARTIFACTS. Run ../build-images.sh --save first."
info "Backend:   $(basename "$BACKEND_TAR")"
info "Frontend:  $(basename "$FRONTEND_TAR")"
info "Manifests: $ARTIFACTS/k8s/"
ok "Artifacts found"

# ---------------------------------------------------------------------------------------------
why "There's no image registry, so each node gets the image files and imports them into containerd's 'k8s.io' namespace, which is where kubelet looks. The manifests use imagePullPolicy: IfNotPresent, so pods start from these local copies."
for node in $(all_node_ips); do
  step "Load images on $node"
  conn "workstation --SSH/SCP tcp/22--> $SSH_USER@$node --> ctr (containerd CLI) --> /run/containerd/containerd.sock"
  ARCH=$(ssh "$SSH_USER@$node" 'dpkg --print-architecture')
  [[ $ARCH == amd64 ]] || warn "$node is $ARCH. Build the images with ../build-images.sh --platform linux/$ARCH --save or the pods will fail with 'exec format error'."
  for tar in "$BACKEND_TAR" "$FRONTEND_TAR"; do
    name=$(basename "$tar")
    run scp -q "$tar" "$SSH_USER@$node:/tmp/$name"
    # -t gives sudo a terminal in case it asks for a password.
    run ssh -t "$SSH_USER@$node" "gunzip -f /tmp/$name && sudo ctr -n k8s.io images import /tmp/${name%.gz} > /dev/null && rm -f /tmp/${name%.gz}"
  done
  ok "Images loaded on $node"
done

# ---------------------------------------------------------------------------------------------
step "Apply Kubernetes manifests"
why "kubectl sends the Deployments and Services to the API server. The scheduler then picks a node for each pod, and that node's kubelet starts the containers from the local images."
conn "workstation kubectl --HTTPS tcp/6443--> kube-apiserver --> etcd (stored) --> scheduler --> kubelet on the chosen node"
kc create namespace "$APP_NAMESPACE" --dry-run=client -o yaml | kc apply -f -
run kc -n "$APP_NAMESPACE" apply -f "$ARTIFACTS/k8s/"
run kc -n "$APP_NAMESPACE" rollout status deployment/nomanualcode-backend --timeout=300s
run kc -n "$APP_NAMESPACE" rollout status deployment/nomanualcode-frontend --timeout=180s
ok "Both deployments are rolled out"

# ---------------------------------------------------------------------------------------------
step "Find the app's address"
why "MetalLB assigns the frontend Service an IP from $METALLB_IP_RANGE."
EXTERNAL_IP=""
for _ in $(seq 1 20); do
  EXTERNAL_IP=$(kc -n "$APP_NAMESPACE" get service nomanualcode-frontend -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  [[ -n $EXTERNAL_IP ]] && break
  sleep 3
done
run kc -n "$APP_NAMESPACE" get pods,services -o wide
conn "browser --> http://${EXTERNAL_IP:-<pending>}:80 --> frontend pod :3000 (Express) --/api/persons--> Service DNS nomanualcode-backend (CoreDNS) --> ClusterIP :8080 --> backend pod :8080 (Spring Boot)"

echo
if [[ -n $EXTERNAL_IP ]]; then
  ok "App is live at http://$EXTERNAL_IP"
else
  warn "The frontend has no external IP yet. Did you run ./04-install-addons.sh? Meanwhile: kubectl -n $APP_NAMESPACE port-forward svc/nomanualcode-frontend 8081:80"
fi
