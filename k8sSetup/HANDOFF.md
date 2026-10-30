# Handoff: continue the k8sSetup on a Linux machine

Session notes from 2026-10-31, written on the Windows workstation. Pick up from **Next steps** once you're on a Linux machine.

## Goal

Move off Docker Desktop's built-in Kubernetes and onto your own cluster running on Linux machines. Each script logs every step, explaining what it does, why, and how the components connect.

## What exists

The `k8sSetup/` folder is built on **kubeadm** (the upstream installer), with **containerd**, **Flannel** for pod networking, and **MetalLB** to give `LoadBalancer` Services a real LAN IP.

| File | Run on | Purpose |
|---|---|---|
| `cluster.env` | edit first | Node IPs, SSH user, K8s version (`v1.36`), pod/service CIDRs, MetalLB IP range |
| `lib/common.sh` | (sourced) | Logging (`step` / `why` / `conn` / `ok` / `warn` / `fail` / `run`), log files, `kc` kubectl wrapper, kubeconfig rename |
| `00-copy-to-nodes.sh` | workstation | Copies `k8sSetup/` to every node over SSH. `--join` passes `join-command.sh` from the control plane to the workers |
| `01-prepare-node.sh --role control-plane\|worker [--node-ip IP]` | every node | Turns off swap, sets kernel modules and sysctls, installs containerd (systemd cgroups, matching pause image), kubelet/kubeadm/kubectl/cri-tools (held at one version), opens ufw ports |
| `02-init-control-plane.sh [--single-node]` | control plane | `kubeadm init`, kubectl for the sudo user (context `own-cluster`), Flannel, writes `join-command.sh` (secret, valid 24h) |
| `03-join-worker.sh [join-file]` | each worker | Checks `https://<cp>:6443/livez`, then `kubeadm join` (token masked in logs) |
| `04-install-addons.sh` | control plane or workstation | MetalLB plus its IPAddressPool and L2Advertisement |
| `05-connect-workstation.sh` | workstation | Adds the `own-cluster` context to `~/.kube/config` next to `docker-desktop` (backs up the file first) |
| `06-deploy-app.sh [artifacts-dir]` | workstation | Copies the image tarballs to each node, `ctr -n k8s.io images import`, applies `artifacts/k8s/`, prints the app URL |
| `verify-cluster.sh` | anywhere with kubectl | API server, nodes, system pods, in-pod DNS, MetalLB and app checks |
| `reset-node.sh` | a node | Wipes the node's Kubernetes state (asks you to type the hostname to confirm) |
| `README.md` | n/a | Architecture diagram, ports table, troubleshooting, switching clusters |

Logs go to `k8sSetup/logs/<script>-<host>-<timestamp>.log` (colour-free) on whichever machine ran the script.

Related files elsewhere in the repo:
- `build-images.sh` (repo root) builds both images. With `--save` it writes `artifacts/*.tar.gz` and `artifacts/k8s/*.yaml` with the exact image tags.
- `k8s/backend.yaml` and `k8s/frontend.yaml` are the manifests:
  - **Backend:** 1 replica, ClusterIP on 8080. It uses in-memory H2, so keep it at 1 replica.
  - **Frontend:** 2 replicas, LoadBalancer on port 80, with `API_URL=http://nomanualcode-backend:8080`.
- `.gitattributes` forces LF line endings on `*.sh` and `*.env`. `.gitignore` excludes `artifacts/`, `k8sSetup/logs/`, `k8sSetup/join-command.sh` and `k8sSetup/.kubeconfig-*`.

## What was tested (on Windows)

- **ShellCheck:** all scripts pass (`-S warning`).
- **Downloads:** pkgs.k8s.io v1.36, the Flannel `latest` manifest and the MetalLB v0.15.2 manifest all return HTTP 200.
- **Ubuntu 24.04 container:**
  - Installed kubeadm v1.36.6 and containerd 2.2.1.
  - `SystemdCgroup = true` and `sandbox = "registry.k8s.io/pause:3.10.2"` applied with the containerd 2.x config format.
  - `crictl` was missing, which led to the fix: `cri-tools` is now installed explicitly.
- **Kubeconfig rename/import:** tested with a fake kubeadm kubeconfig. `docker-desktop` was kept, and the cert data came through intact.
- **Logging:** checked the on-screen output, the log file and the error trap.

## Not tested yet: verify these first on Linux

- `kubeadm init` and `join` on real machines (`02`, `03`)
- Flannel rollout, with nodes turning `Ready`
- MetalLB install and the IP pool webhook retry (`04`)
- The SSH steps: `00`, `05`, `06` (`scp`, `ssh -t`, `sudo ctr images import`)
- `verify-cluster.sh` end to end
- `ufw` rule application (only runs if ufw is active)

## Next steps

1. **Get the code onto the Linux machine.** Nothing is committed yet, so commit and push from Windows first, or copy the repo over. Then check the line endings: `file k8sSetup/*.sh` should **not** say "CRLF".
2. **Edit `k8sSetup/cluster.env`:** `CONTROL_PLANE_IP`, `WORKER_IPS` (empty for a single node), `SSH_USER`, and a free `METALLB_IP_RANGE` in the node subnet, outside the DHCP range.
3. **Set up SSH keys** to every node: `ssh-copy-id <user>@<node>`.
4. **Run, in order:**
   ```sh
   cd k8sSetup
   ./00-copy-to-nodes.sh                                        # workstation
   sudo ./01-prepare-node.sh --role control-plane               # on the control plane
   sudo ./01-prepare-node.sh --role worker                      # on each worker
   sudo ./02-init-control-plane.sh                              # control plane (--single-node if no workers)
   ./00-copy-to-nodes.sh --join                                 # workstation
   sudo ./03-join-worker.sh                                     # each worker
   ./04-install-addons.sh                                       # control plane or workstation
   ./05-connect-workstation.sh                                  # workstation
   ../build-images.sh --save && ./06-deploy-app.sh              # workstation
   ./verify-cluster.sh
   ```
   **Single Linux machine?** Use it as the control plane with `--single-node`, leave `WORKER_IPS` empty, and skip `00 --join` and `03`. If it's also your workstation, `05` and `06` still work over SSH to itself, or just use the kubeconfig `02` wrote.
5. **If a step fails,** read the log file the script names, and bring that log back to Claude.

## Known caveats

- **Image architecture:** images are built for amd64. For ARM nodes, use `build-images.sh --platform linux/arm64 --save`.
- **Single control plane, no HA.** For HA, set `CONTROL_PLANE_ENDPOINT` before `02`.
- **Join token** expires after 24h. Regenerate it with `sudo kubeadm token create --print-join-command`.
- **Admin credentials:** the workstation uses the cluster-admin cert. Create RBAC users for anyone else.
- **Leftover test log:** `k8sSetup/logs/demo-*.log` is from Windows testing and is safe to delete.
- **Windows JDK** (not relevant on Linux): `JAVA_HOME` there points to JDK 27, which Gradle 9.7.1 can't run on. `dev.mjs` picks JDK 26 automatically. On Linux, install JDK 26 if you build the backend outside Docker. `build-images.sh` only needs Docker.

## Prompt to resume with Claude

> I'm continuing the k8sSetup from `k8sSetup/HANDOFF.md` on a Linux machine. Read it and `k8sSetup/README.md`, then help me run the steps. Here's my setup: <node IPs, OS, single-node or multi-node>.
