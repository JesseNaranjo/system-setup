# Kubernetes

Kubernetes cluster setup and configuration suite. Uses an orchestrator pattern with modular scripts for idempotent, repeatable cluster configuration.

## Running

```bash
sudo ./kubernetes-setup.sh           # Interactive mode
sudo ./kubernetes-setup.sh --debug   # Debug mode
```

The Kubernetes version is set via `K8S_VERSION` in `kubernetes-setup.sh` (currently `v1.35`). This controls the APT repository version for both Kubernetes packages and CRI-O. To target a different version, edit the constant before running.

The orchestrator will:
1. Self-update from the remote repository (with diff/prompt before overwriting)
2. Check and update all module scripts
3. Ask which node role this machine will serve
4. Walk through configuration steps based on the selected role

## Structure

| Component | Purpose |
|-----------|---------|
| `kubernetes-setup.sh` | Orchestrator script |
| `utils-k8s.sh` | Shared utilities (fork of system-setup/utils-sys.sh, includes self-update functions) |
| `kubernetes-modules/` | Feature modules (sourced by orchestrator) |
| `start-k8s.sh` | Start Kubernetes services (standalone) |
| `stop-k8s.sh` | Stop Kubernetes services (standalone) |

## Modules

| Module | Purpose |
|--------|---------|
| `configure-kernel-modules.sh` | Load and persist br_netfilter, overlay; configure /dev/kmsg for containers |
| `install-k8s-packages.sh` | Role-based package installation (repos, GPG keys, packages) |
| `configure-networking.sh` | Sysctl settings (IP forwarding, bridge netfilter) |
| `configure-swap.sh` | Disable swap, clean fstab, mask swap.target |
| `configure-crio.sh` | CRI-O runtime configuration and service management |
| `install-update-helm.sh` | Install or update Helm |
| `install-update-minikube.sh` | Install or update Minikube |
| `initialize-cluster.sh` | kubeadm init/join for cluster setup |
| `validate-cluster.sh` | Cluster health checks |
| `manage-certificates.sh` | TLS certificate lifecycle and kubeconfig |
| `configure-kube-editor.sh` | KUBE_EDITOR environment variable |

Each module can also be run standalone: `sudo ./kubernetes-modules/<module>.sh`

Individual scripts and modules self-update when run directly via `check_for_updates()` in `utils-k8s.sh`. When sourced by the orchestrator, the update check is skipped (the orchestrator handles updates itself).

## Adding New Modules

1. Create module in `kubernetes-modules/` following existing patterns
2. Source `utils-k8s.sh` for shared functions
3. Add `main_<module_name>()` entry point with `detect_environment` call
4. Add `# shellcheck source=../utils-k8s.sh` directive
5. Add execution guard: `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main_<name> "$@"; fi`
6. Source and call from `kubernetes-setup.sh` main()
7. Add to `get_script_list()` in `kubernetes-setup.sh`
8. Update this README

## Obsolete Scripts

The following standalone scripts have been replaced by the orchestrator and its modules:

| Old Script | Replaced By |
|------------|-------------|
| `_download-k8s-scripts.sh` | `kubernetes-setup.sh` (self-update) |
| `update-k8s-repos.sh` | `kubernetes-modules/install-k8s-packages.sh` |
| `install-update-helm.sh` (root) | `kubernetes-modules/install-update-helm.sh` |
| `install-update-minikube.sh` (root) | `kubernetes-modules/install-update-minikube.sh` |
| `kubernetes-modules/configure-k8s-repos.sh` | Absorbed into `kubernetes-modules/install-k8s-packages.sh` |

The orchestrator will prompt to delete these if found.

## Operational Scripts

`start-k8s.sh` and `stop-k8s.sh` are standalone scripts that source `utils-k8s.sh` for shared functions. They require root privileges (`sudo`).

### start everything

```
sudo ./start-k8s.sh
```
- Sources `utils-k8s.sh` for shared utilities
- Idempotent pre-checks (swap state, IP forwarding, /dev/kmsg in containers)
- Enables and starts kubelet and crio services
- Shows service and cluster status after starting
- Requires root privileges

### stop everything

```
sudo ./stop-k8s.sh
```
- Sources `utils-k8s.sh` for shared utilities
- Stops and disables `kubelet.service` and `crio.service`
- Re-enables swap (`swapon -a`) with graceful handling if no swap devices exist
- Disables IP forwarding (idempotent check)
- Requires root privileges
- Use this when you want to temporarily stop Kubernetes without removing the cluster configuration

## Cluster Setup Reference

### Initialize control-plane node

```
kubeadm init --config=/etc/kubernetes/kubeadm-config.yaml
```
- The orchestrator generates the config file with pod CIDR and container-specific settings
- Example CIDR: `192.168.0.0/16` (Calico default)
- Save the `kubeadm join` command from the output
- Reset with `kubeadm reset` (see [cleanup](#cleanup) section)

### Join additional nodes

Run the `kubeadm join` command from the `kubeadm init` output<sup>1</sup>:
```
kubeadm join xxx.xxx.xxx.xxx:6443 --token abcdef.ghijklmnopqrstuv --discovery-token-ca-cert-hash sha256:01234567890abcdef0123456789abcdef0123456789abcdef0123456789abcde
```

If the token has expired:
```
kubeadm token create --print-join-command
```

### Configure network policy (optional)

```
kubectl apply -f <add-on.yaml>
```
- Calico for small-scale pods, easy entry-level effort
  - https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises
  - https://github.com/projectcalico/calico/tree/master/manifests
- Cilium for large-scale pods, steep learning curve, uses eBPF
- Popular addons: https://kubernetes.io/docs/concepts/cluster-administration/addons/

### Control-plane as worker node (single node)

```
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

## Persistent Configuration Reference

These configurations are managed automatically by the orchestrator modules, but documented here for reference:

**Kernel modules** (`/etc/modules-load.d/k8s.conf`):
```
br_netfilter
overlay
```

**Sysctl settings** (`/etc/sysctl.d/k8s.conf`):
```
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
```

**Swap**: Disabled in `/etc/fstab` and via `systemctl mask swap.target`

**Device nodes** (`/etc/tmpfiles.d/kmsg.conf`, containers only):
```
L /dev/kmsg - - - - /dev/null
```
kubelet requires `/dev/kmsg` which LXC containers lack. Symlinks to `/dev/null` (not `/dev/console`) to avoid a journald infinite loop. Created at boot by `systemd-tmpfiles-setup-dev.service`.

## Other Packages

- Helm - https://helm.sh/docs/intro/install/
- Metrics Server
  - https://github.com/kubernetes-sigs/metrics-server
  - https://artifacthub.io/packages/helm/metrics-server/metrics-server
- Kubernetes Dashboard
  - https://github.com/kubernetes/dashboard
  - https://artifacthub.io/packages/helm/k8s-dashboard/kubernetes-dashboard

## Firewall / Required Ports

### Control-plane node

| Port | Protocol | Purpose |
|------|----------|----------|
| 6443 | TCP | Kubernetes API server |
| 2379-2380 | TCP | etcd server client API |
| 10250 | TCP | Kubelet API |
| 10259 | TCP | kube-scheduler |
| 10257 | TCP | kube-controller-manager |

### Worker nodes

| Port | Protocol | Purpose |
|------|----------|----------|
| 10250 | TCP | Kubelet API |
| 10256 | TCP | kube-proxy |
| 30000-32767 | TCP | NodePort Services |

References:
- https://kubernetes.io/docs/reference/networking/ports-and-protocols/

## Running in LXC Containers

When running Kubernetes inside LXC containers, additional prerequisites must be met on the **host** side:

### 1. Kernel config must be accessible

kubeadm's `SystemVerification` preflight check needs the kernel config. LXC containers share the host kernel but lack `/boot/config-*`. Copy it from the host:

```bash
# On the host:
mkdir -p ~/.local/share/lxc/<container>/rootfs/boot
cp /boot/config-$(uname -r) ~/.local/share/lxc/<container>/rootfs/boot/
```

### 2. Swap handling (automatic)

`/proc/swaps` inside the container reflects the host's swap devices via LXCFS. `swapoff -a` fails (no `CAP_SYS_ADMIN`), and bind-mounting `/dev/null` over `/proc/swaps` is overridden by LXCFS.

`initialize-cluster.sh` handles this automatically by generating a kubeadm config with `failSwapOn: false` when it detects a container environment. No manual action is required.

For cgroup-level swap restriction (prevents the container from actually using host swap), use `start-lxc.sh --k8s` on the host:

```bash
# From the lxc/ directory:
sudo ./start-lxc.sh --privileged --k8s tst-k8s1
```

### 3. /proc/sys writability (privileged containers)

In privileged LXC containers, `/proc/sys` is read-only by default (LXC `proc:mixed` mount mode). The kubelet needs to write kernel tunables (`vm.overcommit_memory`, `kernel.panic`, etc.). The `KubeletInUserNamespace` feature gate does not help because privileged containers have no user namespace.

Fix: start the container with `--k8s` to mount `/proc` and `/sys` read-write:

```bash
sudo ./start-lxc.sh --privileged --k8s tst-k8s1
```

The `initialize-cluster.sh` preflight check will detect read-only `/proc/sys` and fail early with guidance.

### 4. /dev/kmsg (automatic)

kubelet's OOM watcher requires `/dev/kmsg`, which LXC containers don't provide. The orchestrator's Step 1 (Kernel Modules) installs a `tmpfiles.d` config that creates `/dev/kmsg -> /dev/null` at every boot. `start-k8s.sh` also verifies this before starting services. No manual action is required.

See the [`lxc/`](../lxc/) directory for container management scripts.

## Troubleshooting

### Check service status

```
sudo systemctl status kubelet crio
```

### View kubelet logs

```
journalctl -xeu kubelet
```

### View cri-o logs

```
journalctl -xeu crio
```

### Verify container runtime

```
sudo crictl info
```
- CRI-O socket path: `/var/run/crio/crio.sock`

### Common errors

**"swap is enabled on the node"**
- Ensure swap is disabled: `sudo swapoff -a`
- For persistent disable, run the orchestrator or see [persistent configuration](#persistent-configuration-reference)

**"br_netfilter" or "overlay" module not loaded**
- Load the required modules:
  ```
  sudo modprobe br_netfilter
  sudo modprobe overlay
  ```
- In container environments (LXC, Docker), modules must be loaded on the **host**. The orchestrator will detect this and skip `modprobe` automatically.
- For persistent loading, run the orchestrator or see [persistent configuration](#persistent-configuration-reference)

**"token is invalid" or "token has expired"**
- List existing tokens: `kubeadm token list`
- Create a new token: `kubeadm token create`
- Generate a new join command: `kubeadm token create --print-join-command`

**kubelet keeps crashing / CrashLoopBackOff**
- Check if container runtime is running: `sudo systemctl status crio`
- Check kubelet logs: `journalctl -xeu kubelet`
- Verify node is initialized: `kubectl get nodes`

**Cannot connect to the cluster**
- Ensure kubeconfig is set up:
  ```
  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
  ```

## Cleanup

### Remove node

Cleanly shutdown and drain all containers/pods from the node:
```
kubectl drain <node name> --delete-emptydir-data --force --ignore-daemonsets
```

### Reset kubernetes setup<sup>1</sup>

```
kubeadm reset
```

### Clean up iptables<sup>1</sup>

```
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
ipvsadm -C
```

References:
- https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#tear-down

## Credits

- https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
- https://www.webhi.com/how-to/setup-configure-kubernetes-on-ubuntu-debian-and-centos-rhel/

## Notes

<sup>1</sup> Running this command requires elevated privileges (`sudo` or `su`).
