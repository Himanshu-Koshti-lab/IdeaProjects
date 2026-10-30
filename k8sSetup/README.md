# k8sSetup: your own Kubernetes cluster

Scripts to replace Docker Desktop's built-in Kubernetes with a cluster you run on your own Linux machines (VMs, mini PCs or servers). They use **kubeadm**, the upstream installer, with **containerd** as the runtime, **Flannel** for pod networking and **MetalLB** so `LoadBalancer` Services get a real IP on your LAN.

Every script logs each step with a `why:` line (the reason for the step) and a `connects:` line (which component talks to which, over what port). A colour-free copy of everything goes to `k8sSetup/logs/<script>-<host>-<time>.log` on the machine that ran it.

## What you get

```
                       your LAN (e.g. 192.168.1.0/24)
 ┌──────────────┐
 │ workstation  │  kubectl ──HTTPS 6443──────────┐
 │ (this PC)    │  ssh/scp ──22──► every node     │
 └──────────────┘                                 ▼
 ┌─────────────────────────────┐   ┌──────────────────────────┐   ┌──────────────────────────┐
 │ control plane 192.168.1.10  │   │ worker 192.168.1.11      │   │ worker 192.168.1.12      │
 │  kube-apiserver :6443 ◄─────┼───┤  kubelet ── containerd   │   │  kubelet ── containerd   │
 │  etcd :2379 (local only)    │   │  kube-proxy, flannel     │   │  kube-proxy, flannel     │
 │  scheduler, controller-mgr  │   │  MetalLB speaker         │   │  MetalLB speaker         │
 │  kubelet ── containerd      │   │  app pods                │   │  app pods                │
 └──────────────┬──────────────┘   └────────────┬─────────────┘   └────────────┬─────────────┘
                └──────── pod traffic between nodes: Flannel VXLAN, UDP 8472 ───┘

 browser ──► http://192.168.1.240 (MetalLB IP) ──► frontend pod :3000 ──► nomanualcode-backend:8080 ──► backend pod
```

- **Everything goes through the API server.** kubelets, the scheduler, controllers and your kubectl only ever talk to `kube-apiserver` on 6443 over mutual TLS. Only the API server talks to etcd.
- **Pods get IPs from `POD_CIDR`** (a /24 per node). Traffic to a pod on another node is wrapped in VXLAN and sent to that node's IP.
- **Services get virtual IPs from `SERVICE_CIDR`.** kube-proxy rewrites them to real pod IPs with iptables on every node, and CoreDNS resolves Service names like `nomanualcode-backend`.
- **LoadBalancer IPs come from `METALLB_IP_RANGE`.** One node answers ARP for each IP, then kube-proxy forwards the traffic to a pod.

## Requirements

- **Nodes:** 1 or more Linux machines running Ubuntu 22.04/24.04 or Debian 12, on amd64 (or build the images with `--platform`).
  - **Control plane:** at least 2 CPUs and 2 GB RAM.
  - **Workers:** at least 1 CPU and 2 GB RAM.
  - **Network:** a unique hostname per node, and all nodes on one network that can reach each other.
- **SSH:** an SSH user with sudo on every node. Use keys (`ssh-copy-id ubuntu@192.168.1.10`) so the workstation scripts don't prompt.
- **Workstation:** this PC, with Git Bash, `kubectl` (Docker Desktop ships it) and Docker for building images.

## Steps

**1. Edit `cluster.env`.** Set the node IPs, the SSH user and a free IP range for MetalLB. All scripts read this one file.

**2. Copy the scripts to the nodes** (on your workstation, from `k8sSetup/`):
```sh
./00-copy-to-nodes.sh
```

**3. Prepare every node** (on each node, over SSH):
```sh
cd ~/k8sSetup
sudo ./01-prepare-node.sh --role control-plane     # on the control plane
sudo ./01-prepare-node.sh --role worker            # on each worker
```
This disables swap and sets up the kernel modules and sysctls. It installs containerd with systemd cgroups, then installs kubelet, kubeadm and kubectl pinned to `K8S_VERSION`. It also opens firewall ports if ufw is on.

**4. Create the cluster** (on the control plane):
```sh
sudo ./02-init-control-plane.sh                    # add --single-node if you have no workers
```
This runs `kubeadm init`, sets up kubectl for your user and installs Flannel, then writes `join-command.sh`. That file is secret and valid for 24h.

**5. Join the workers:**
```sh
./00-copy-to-nodes.sh --join                       # workstation: relays join-command.sh to the workers
sudo ./03-join-worker.sh                           # on each worker
```

**6. Install MetalLB** (on the control plane, or the workstation after step 7):
```sh
./04-install-addons.sh
```

**7. Connect your workstation:**
```sh
./05-connect-workstation.sh
```
This adds the context `own-cluster` to `~/.kube/config` next to `docker-desktop`, after backing up the file, and switches to it.

**8. Build and deploy the app:**
```sh
../build-images.sh --save                          # from the repo root: images + manifests into artifacts/
./06-deploy-app.sh
```
No registry is needed: the image tarballs are copied to every node and imported into containerd. The script prints the app's URL at the end.

**Any time:** run `./verify-cluster.sh` to check the API server, nodes, system pods, DNS from inside a pod, MetalLB and the app.

## Ports

| Port | Where | Used by |
|---|---|---|
| 6443/tcp | control plane | kube-apiserver: kubectl, kubelets and pods |
| 2379-2380/tcp | control plane | etcd (API server only) |
| 10250/tcp | all nodes | kubelet API: logs, exec, port-forward |
| 8472/udp | all nodes | Flannel VXLAN pod traffic |
| 7946/tcp+udp | all nodes | MetalLB speaker coordination |
| 30000-32767/tcp | all nodes | NodePort Services |
| 22/tcp | all nodes | SSH from your workstation (scripts 00, 05, 06) |

## Switching between clusters

```sh
kubectl config get-contexts
kubectl config use-context own-cluster       # your cluster
kubectl config use-context docker-desktop    # back to Docker Desktop
```

## Troubleshooting

| Symptom | Look at |
|---|---|
| Node `NotReady` | `journalctl -u kubelet -e` on that node; `kubectl -n kube-flannel get pods -o wide` |
| Join hangs | Can the worker reach `https://<control-plane>:6443/livez`? Is the token older than 24h? Regenerate it with `sudo kubeadm token create --print-join-command` |
| Pods `ImagePullBackOff` for the app | The image wasn't imported on that node: `sudo crictl images \| grep nomanualcode` |
| `exec format error` | The image architecture doesn't match the node. Build with `--platform linux/arm64` (or whichever the node uses) |
| Frontend `EXTERNAL-IP <pending>` | MetalLB isn't installed, or the IP pool is in the wrong subnet |

To start a node over: `sudo ./reset-node.sh`. It asks for confirmation. On the control plane this destroys the whole cluster.

## Limits of this setup

- **Single control plane.** If that machine is down, the cluster can't be managed, though running pods keep serving. For high availability, set `CONTROL_PLANE_ENDPOINT` to a load-balanced name and add more control planes with `kubeadm join --control-plane`.
- **Admin credentials.** The workstation uses the cluster-admin certificate. For other people, create separate users or ServiceAccounts with RBAC.
- **Certificate expiry.** Certificates expire after 1 year. kubeadm renews them automatically on upgrades; otherwise run `sudo kubeadm certs renew all`.
