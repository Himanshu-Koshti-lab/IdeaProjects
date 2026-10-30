#!/usr/bin/env bash
# Run on your WORKSTATION (Git Bash on Windows, macOS or Linux). Fetches the cluster's admin
# credentials from the control plane and adds them to ~/.kube/config as context "$CLUSTER_NAME",
# next to docker-desktop.
#
#   ./05-connect-workstation.sh
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

start_logging
banner "Connect this workstation's kubectl to $CLUSTER_NAME"
require_cmd ssh ""
require_cmd kubectl "Docker Desktop ships one, or see https://kubernetes.io/docs/tasks/tools/"

API_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-$CONTROL_PLANE_IP}:6443"

# ---------------------------------------------------------------------------------------------
step "Check the network path to the API server"
why "kubectl is only an HTTPS client of kube-apiserver. If this machine can't reach port 6443, nothing else will work."
conn "workstation kubectl --HTTPS tcp/6443--> https://$API_ENDPOINT"
if [[ $(curl -sk --max-time 5 "https://$API_ENDPOINT/livez") == ok ]]; then
  ok "API server answered /livez = ok"
else
  fail "Can't reach https://$API_ENDPOINT. Is the control plane initialised (02)? Is tcp/6443 open from this machine?"
fi

# ---------------------------------------------------------------------------------------------
step "Fetch admin kubeconfig from $SSH_USER@$CONTROL_PLANE_IP"
why "02-init-control-plane.sh placed a copy in ~/.kube/config of the user who ran it. It holds the cluster CA plus an admin client certificate."
conn "workstation --SSH tcp/22--> $SSH_USER@$CONTROL_PLANE_IP"
cd "$SETUP_DIR"
TMP_CONFIG=".kubeconfig-$CLUSTER_NAME.tmp"
trap 'rm -f "$SETUP_DIR/$TMP_CONFIG"' EXIT
( umask 077
  ssh "$SSH_USER@$CONTROL_PLANE_IP" 'cat ~/.kube/config 2>/dev/null || sudo -n cat /etc/kubernetes/admin.conf' \
    | rename_kubeconfig > "$TMP_CONFIG" )
grep -q "certificate-authority-data" "$TMP_CONFIG" || fail "Didn't get a valid kubeconfig. Run 02 with sudo as $SSH_USER, or allow passwordless sudo."
ok "Credentials fetched (kept only in memory and a temp file that's deleted on exit)"

# ---------------------------------------------------------------------------------------------
step "Add context '$CLUSTER_NAME' to your kubeconfig"
why "Adding cluster, user and context entries one by one with 'kubectl config set' leaves your other contexts (docker-desktop) untouched, and works the same on Windows, macOS and Linux."
conn "kubectl verifies the API server's certificate against the cluster CA, then presents the admin client certificate (CN=kubernetes-admin, group kubeadm:cluster-admins). RBAC maps that group to cluster-admin."
field() { kubectl --kubeconfig "$TMP_CONFIG" config view --raw -o jsonpath="$1"; }
SERVER=$(field '{.clusters[0].cluster.server}')
CA_DATA=$(field '{.clusters[0].cluster.certificate-authority-data}')
CERT_DATA=$(field '{.users[0].user.client-certificate-data}')
KEY_DATA=$(field '{.users[0].user.client-key-data}')
if [[ -f "$HOME/.kube/config" ]]; then
  BACKUP="$HOME/.kube/config.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$HOME/.kube/config" "$BACKUP"
  info "Backed up existing kubeconfig to $BACKUP"
fi
info "Server: $SERVER"
kubectl config set-cluster "$CLUSTER_NAME" --server="$SERVER" > /dev/null
kubectl config set "clusters.$CLUSTER_NAME.certificate-authority-data" "$CA_DATA" > /dev/null
kubectl config set "users.$CLUSTER_NAME-admin.client-certificate-data" "$CERT_DATA" > /dev/null
kubectl config set "users.$CLUSTER_NAME-admin.client-key-data" "$KEY_DATA" > /dev/null
kubectl config set-context "$CLUSTER_NAME" --cluster="$CLUSTER_NAME" --user="$CLUSTER_NAME-admin" > /dev/null
run kubectl config use-context "$CLUSTER_NAME"
ok "kubectl now talks to $CLUSTER_NAME by default"

# ---------------------------------------------------------------------------------------------
step "Verify"
run kubectl get nodes -o wide
run kubectl cluster-info

echo
ok "Workstation connected"
info "Switch clusters:  kubectl config use-context docker-desktop   |   kubectl config use-context $CLUSTER_NAME"
