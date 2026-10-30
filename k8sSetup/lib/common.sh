# shellcheck shell=bash
# Shared helpers sourced by every k8sSetup script: config loading, logging and a kubectl wrapper.

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../cluster.env
source "$SETUP_DIR/cluster.env"

if [[ -t 1 ]]; then
  BOLD=$'\e[1m' DIM=$'\e[2m' RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' BLUE=$'\e[34m' CYAN=$'\e[36m' RESET=$'\e[0m'
else
  BOLD='' DIM='' RED='' GREEN='' YELLOW='' BLUE='' CYAN='' RESET=''
fi

STEP_NO=0
ts() { date '+%H:%M:%S'; }

# --- Logging ---------------------------------------------------------------------------------
# Every line (including command output and errors) goes to the terminal and, without colour
# codes, to logs/<script>-<host>-<timestamp>.log.
start_logging() {
  local dir="$SETUP_DIR/logs"
  mkdir -p "$dir"
  LOG_FILE="$dir/$(basename "$0" .sh)-$(hostname)-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee >(sed -E "s/"$'\e'"\[[0-9;]*m//g" >> "$LOG_FILE")) 2>&1
  trap 'on_error $LINENO "$BASH_COMMAND"' ERR
  info "Full log: $LOG_FILE"
}

on_error() {
  printf '\n%s[%s] FAILED at line %s: %s%s\n' "$RED$BOLD" "$(ts)" "$1" "$2" "$RESET"
  printf '%sSee the full log: %s%s\n' "$RED" "${LOG_FILE:-<not started>}" "$RESET"
}

banner() {
  printf '%s\n' "$BOLD$BLUE================================================================================"
  printf ' %s\n' "$*"
  printf ' host=%s  user=%s  started=%s\n' "$(hostname)" "$(id -un)" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s\n' "================================================================================$RESET"
}

step() { STEP_NO=$((STEP_NO + 1)); printf '\n%s[%s] STEP %d: %s%s\n' "$BOLD$BLUE" "$(ts)" "$STEP_NO" "$*" "$RESET"; }
why()  { printf '%s      why:      %s%s\n' "$DIM" "$*" "$RESET"; }
conn() { printf '%s      connects: %s%s\n' "$CYAN" "$*" "$RESET"; }
info() { printf '[%s] INFO  %s\n' "$(ts)" "$*"; }
ok()   { printf '%s[%s] OK    %s%s\n' "$GREEN" "$(ts)" "$*" "$RESET"; }
warn() { printf '%s[%s] WARN  %s%s\n' "$YELLOW" "$(ts)" "$*" "$RESET"; }
fail() { printf '%s[%s] ERROR %s%s\n' "$RED" "$(ts)" "$*" "$RESET" >&2; exit 1; }

# Prints the command, then runs it.
run() { printf '%s      $ %s%s\n' "$DIM" "$*" "$RESET"; "$@"; }

# --- Checks ----------------------------------------------------------------------------------
require_root() { [[ $EUID -eq 0 ]] || fail "Run as root: sudo $0 $*"; }
require_cmd()  { command -v "$1" > /dev/null || fail "'$1' is not installed or not on PATH. $2"; }

all_node_ips() { echo "$CONTROL_PLANE_IP $WORKER_IPS"; }

# --- kubectl ---------------------------------------------------------------------------------
# On the control plane as root, use the admin kubeconfig kubeadm wrote. Everywhere else (your
# workstation, or the control plane as a normal user) use the context 05-connect-workstation.sh
# or 02-init-control-plane.sh created.
kc() {
  if [[ $EUID -eq 0 && -r /etc/kubernetes/admin.conf ]]; then
    kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"
  else
    kubectl --context "$CLUSTER_NAME" "$@"
  fi
}

# kubeadm names everything "kubernetes" / "kubernetes-admin". Rename to $CLUSTER_NAME so it can
# sit next to other clusters (e.g. docker-desktop) in one kubeconfig without clashing.
rename_kubeconfig() {
  sed -E -e "s/kubernetes-admin@kubernetes/$CLUSTER_NAME/g" \
         -e "s/(user|name): kubernetes-admin$/\1: $CLUSTER_NAME-admin/" \
         -e "s/(cluster|name): kubernetes$/\1: $CLUSTER_NAME/"
}
