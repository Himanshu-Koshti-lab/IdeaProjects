#!/usr/bin/env bash
# Run on EVERY Linux node (control plane and workers) as root. Installs the container runtime,
# kubelet/kubeadm/kubectl and the kernel settings Kubernetes networking needs.
#
#   sudo ./01-prepare-node.sh --role control-plane [--node-ip 192.168.1.10]
#   sudo ./01-prepare-node.sh --role worker        [--node-ip 192.168.1.11]
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ROLE=worker
NODE_IP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)    ROLE="$2"; shift 2 ;;
    --node-ip) NODE_IP="$2"; shift 2 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done
[[ $ROLE == control-plane || $ROLE == worker ]] || fail "--role must be control-plane or worker"

require_root
start_logging
banner "Prepare $(hostname) as a Kubernetes $ROLE node (Kubernetes $K8S_VERSION)"

# ---------------------------------------------------------------------------------------------
step "Check the machine"
why "kubeadm's preflight checks need a supported Linux, 2+ CPUs / 2 GB RAM on the control plane, and a unique hostname per node (the hostname becomes the node name)."
# shellcheck source=/dev/null
. /etc/os-release
RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
info "OS $PRETTY_NAME | kernel $(uname -r) | arch $(dpkg --print-architecture) | CPUs $(nproc) | RAM ${RAM_MB} MB"
[[ $ID == ubuntu || $ID == debian ]] || fail "Unsupported OS '$ID'. These scripts use apt (Ubuntu 22.04/24.04, Debian 12)."
if [[ $ROLE == control-plane && $(nproc) -lt 2 ]]; then fail "The control plane needs at least 2 CPUs."; fi
(( RAM_MB >= 1700 )) || warn "Less than 2 GB RAM: kubeadm will complain and pods may be evicted."
if [[ -z $NODE_IP ]]; then
  NODE_IP=$(ip -4 route get 1.1.1.1 | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
  info "No --node-ip given; using the IP of the default route: $NODE_IP"
fi
ip -4 -o addr | grep -qw "$NODE_IP" || fail "$NODE_IP is not an address of this machine."
if [[ $ROLE == control-plane && $NODE_IP != "$CONTROL_PLANE_IP" ]]; then
  fail "This node's IP ($NODE_IP) differs from CONTROL_PLANE_IP ($CONTROL_PLANE_IP) in cluster.env."
fi
info "Hostname: $(hostname)   Node IP: $NODE_IP"
conn "Other nodes and the control plane will reach this node's kubelet and pods via $NODE_IP."
ok "Machine looks suitable"

# ---------------------------------------------------------------------------------------------
step "Disable swap"
why "kubelet refuses to start with swap on by default: memory limits and pod eviction assume the RAM it sees is real RAM."
run swapoff -a
run sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab
ok "Swap off now and after reboot"

# ---------------------------------------------------------------------------------------------
step "Load kernel modules: overlay, br_netfilter"
why "overlay: containerd stores image layers with the overlay filesystem. br_netfilter: lets iptables see traffic crossing the Linux bridge pods are plugged into, which Service routing (kube-proxy) relies on."
printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
run modprobe overlay
run modprobe br_netfilter
ok "Modules loaded and set to load at boot (/etc/modules-load.d/k8s.conf)"

# ---------------------------------------------------------------------------------------------
step "Kernel networking settings (sysctl)"
why "ip_forward: this node must route packets between pods on different nodes. bridge-nf-call-*: run bridged pod traffic through iptables so Service virtual IPs get translated to pod IPs."
cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
run sysctl --system > /dev/null
info "net.ipv4.ip_forward=$(sysctl -n net.ipv4.ip_forward) net.bridge.bridge-nf-call-iptables=$(sysctl -n net.bridge.bridge-nf-call-iptables)"
ok "Applied (/etc/sysctl.d/k8s.conf)"

# ---------------------------------------------------------------------------------------------
step "Install containerd (container runtime) and apt prerequisites"
why "Kubernetes doesn't run containers itself. kubelet asks a CRI runtime to do it. containerd is the standard one (Docker Desktop's cluster uses it too)."
conn "kubelet --CRI gRPC--> unix:///run/containerd/containerd.sock --> containerd --> runc --> container processes"
export DEBIAN_FRONTEND=noninteractive
run apt-get update -q
run apt-get install -y -q containerd apt-transport-https ca-certificates curl gpg
ok "containerd $(containerd --version | awk '{print $3}') installed"

# ---------------------------------------------------------------------------------------------
step "Install kubelet, kubeadm, kubectl ($K8S_VERSION) from pkgs.k8s.io"
why "kubeadm bootstraps the cluster, kubelet is the agent that runs pods on each node, kubectl is the CLI. They're pinned to one minor version and held, so 'apt upgrade' can't leave nodes on mismatched versions."
conn "apt --HTTPS--> pkgs.k8s.io (official Kubernetes package repo)"
install -d -m 755 /etc/apt/keyrings
run bash -c "curl -fsSL https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/deb/Release.key | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg"
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
run apt-get update -q
run apt-get install -y -q kubelet kubeadm kubectl cri-tools
run apt-mark hold kubelet kubeadm kubectl
ok "Installed $(kubeadm version -o short) (held)"

# ---------------------------------------------------------------------------------------------
step "Configure containerd: systemd cgroups + matching pause image"
why "kubelet manages resources through systemd cgroups. If containerd used a different cgroup driver, two managers would fight over the same processes and pods would restart randomly."
why "Every pod starts with a tiny 'pause' container that holds its network namespace; use the exact version kubeadm expects."
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml || fail "Could not enable SystemdCgroup in /etc/containerd/config.toml"
PAUSE_IMAGE=$(kubeadm config images list --kubernetes-version "$(kubeadm version -o short)" 2> /dev/null | grep pause)
sed -i -E "s#^(\s*)(sandbox_image|sandbox) = .*#\1\2 = \"$PAUSE_IMAGE\"#" /etc/containerd/config.toml
info "SystemdCgroup = true, pause image = $PAUSE_IMAGE"
run systemctl restart containerd
run systemctl enable containerd
run crictl config --set runtime-endpoint=unix:///run/containerd/containerd.sock
ok "containerd is $(systemctl is-active containerd); 'crictl ps' now inspects Kubernetes containers"

# ---------------------------------------------------------------------------------------------
step "Configure kubelet to advertise $NODE_IP"
why "On machines with several network interfaces, kubelet might advertise the wrong one and other nodes couldn't reach this node's pods."
echo "KUBELET_EXTRA_ARGS=--node-ip=$NODE_IP" > /etc/default/kubelet
run systemctl enable kubelet
info "kubelet will restart in a loop until 'kubeadm init' or 'kubeadm join' gives it a config. That's expected."
ok "kubelet enabled"

# ---------------------------------------------------------------------------------------------
step "Firewall ports for a $ROLE node"
why "Kubernetes components talk to each other over these ports. If a firewall blocks one, nodes stay NotReady or pods can't reach each other."
PORTS=()
if [[ $ROLE == control-plane ]]; then
  PORTS+=(
    "6443/tcp|kube-apiserver: kubectl, every kubelet and pods talk to the cluster through this"
    "2379:2380/tcp|etcd: the cluster database (only the API server uses it)"
    "10257/tcp|kube-controller-manager health"
    "10259/tcp|kube-scheduler health"
  )
fi
PORTS+=(
  "10250/tcp|kubelet API: control plane fetches logs, runs exec/port-forward on this node"
  "10256/tcp|kube-proxy health check"
  "8472/udp|Flannel VXLAN: pod-to-pod traffic between nodes, wrapped in UDP"
  "30000:32767/tcp|NodePort Services"
  "7946/tcp|MetalLB memberlist: speakers agree who announces each LoadBalancer IP"
  "7946/udp|MetalLB memberlist"
)
for entry in "${PORTS[@]}"; do conn "$(printf '%-16s %s' "${entry%%|*}" "${entry#*|}")"; done
if command -v ufw > /dev/null && ufw status | grep -q 'Status: active'; then
  for entry in "${PORTS[@]}"; do run ufw allow "${entry%%|*}" comment "k8s: ${entry#*|}" > /dev/null; done
  why "ufw drops forwarded (routed) packets by default, which would block pod traffic passing through this node."
  run ufw default allow routed
  ok "ufw rules added"
else
  info "ufw is not active, so nothing to open on this machine. If a cloud security group or router firewall sits between nodes, open the ports above there."
fi

# ---------------------------------------------------------------------------------------------
echo
ok "$(hostname) is prepared as a $ROLE node"
if [[ $ROLE == control-plane ]]; then
  info "Next on this machine:  sudo ./02-init-control-plane.sh   (add --single-node to run app pods here too)"
else
  info "Next: initialise the control plane (02), then on this machine:  sudo ./03-join-worker.sh"
fi
