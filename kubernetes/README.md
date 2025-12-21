## Readme

## prerequisites

Install required packages:
- `gpg` - required before adding the Kubernetes package repositories
- `curl` - required by the Helm installer and download scripts

Load required kernel modules:
```
sudo modprobe br_netfilter
sudo modprobe overlay
```
- These modules are required for container networking to function properly
- See the [always running](#always-running) section for how to make these persistent

Edit `update-k8s-repos.sh` and make sure `K8S_VERSION` reflects the most current version of Kubernetes
- You can find the most recent version at https://kubernetes.io/releases/
- Note that this script will add repositories for:
  - Kubernetes
  - CRI-O (versions are aligned with Kubernetes)

Run `update-k8s-repos.sh`<sup>1</sup>

### auto-update scripts

Run `_download-k8s-scripts.sh` to automatically download or update all managed scripts from the remote repository:
- `install-update-helm.sh`
- `start-k8s.sh`
- `stop-k8s.sh`
- `update-k8s-repos.sh`

**Note:** Running this script may overwrite local modifications, including changes to `K8S_VERSION` in `update-k8s-repos.sh`. The script will show diffs and prompt for confirmation before overwriting
- This will download the public signing key for the package repositories listed above.
- And also add the package repositories to the deb sources.

Configure `KUBE_EDITOR`
- Add `export KUBE_EDITOR="/usr/bin/nano"` in `~/.bashrc`, `~/.zshrc`, `~/.profile`, etc. (only in one place)
- *Use your favorite editor in place of nano*

## install k8s

Install packages:
- `kubeadm`
- `kubectl`
- `kubelet`

Credit:
- I used a few different sources to get the right combination of install that work for me. I chose to **not** use Kubernete's install script available in their docs. Source links are down below.
- https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
- https://www.webhi.com/how-to/setup-configure-kubernetes-on-ubuntu-debian-and-centos-rhel/

## install cri-o

Install package:
- `cri-o`

## start everything

```
./start-k8s.sh
```
- This script will ensure all pre-checks are done (such as swapoff, IP forwarding, etc.)
- And then the script will enable and run all services - kubelet and crio

## stop everything

```
./stop-k8s.sh
```
- This script reverses the start configuration:
  - Stops and disables `kubelet.service` and `crio.service`
  - Re-enables swap (`swapon -a`)
  - Disables IP forwarding (`net.ipv4.conf.all.forwarding=0`)
- Use this when you want to temporarily stop Kubernetes without removing the cluster configuration

## initialize control-plane node (not an additional node)

The control-plane is the primary node that coordinates and manages all nodes. If you're setting up an additional node (not a control-plane), then skip this section.

```
kubeadm init --pod-network-cidr=<cidr>
```
- Example of a `<cidr>` is `192.168.0.0/16`
- Save the `kubeadm join` command from the `kubeadm init` output - this is the command to join additional nodes to your cluster
  - More info: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#tear-down
- This can be reset using `kubeadm reset` (alternatively, see [cleanup](#cleanup) section below)
  - More info: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#remove-the-node

## initialize / join additional nodes

Run the `kubeadm join` command that you saved from the `kubeadm init` output. The command<sup>1</sup> generally looks like this:
```
kubeadm join xxx.xxx.xxx.xxx:6443 --token abcdef.ghijklmnopqrstuv --discovery-token-ca-cert-hash sha256:01234567890abcdef0123456789abcdef0123456789abcdef0123456789abcde
```

If you get authentication errors, e.g. the token is invalid, first check if the token still exists using this command<sup>1</sup>:
```
kubeadm token list
```

If the token doesn't exist, you can create one using this command<sup>1</sup>:
```
kubeadm token create
```

## configure network policy (optional)

```
kubectl apply -f <add-on.yaml>
```
- *<add-on.yaml>* can be a local file or a URL
- Calico for small-scale pods, easy entry-level effort
  - YAML file should be available at https://github.com/projectcalico/calico/tree/master/manifests
  - https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises
- Cilium for large-scale pods, steep learning curve, uses eBPF
- Popular addons: https://kubernetes.io/docs/concepts/cluster-administration/addons/

Credit:
- https://www.reddit.com/r/kubernetes/comments/1110k8p/suggestions_for_k8s_cni/

## configure k8s

### always running

If your install is to have k8s always running, you must make the following configurations persistent:

**Permanently disable swap:**

Comment out the swap entry in `/etc/fstab`:
```
# /dev/sdXn none swap sw 0 0
```
Or disable swap via systemd:
```
sudo systemctl mask swap.target
```

**Permanently enable IP forwarding:**

Create `/etc/sysctl.d/k8s.conf`:
```
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
```
Apply with `sudo sysctl --system`

**Permanently load kernel modules:**

Create `/etc/modules-load.d/k8s.conf`:
```
br_netfilter
overlay
```

### control-plane node as worker node (aka, single node)

If you want the control-plane node to run pods or your install is a single node, then you must execute the following command:
```
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

## other packages to install

- Helm - https://helm.sh/docs/intro/install/ (see install-update-helm.sh)
- Metrics Server
  - https://github.com/kubernetes-sigs/metrics-server
  - https://artifacthub.io/packages/helm/metrics-server/metrics-server
- Kubernetes Dashboard
  - https://github.com/kubernetes/dashboard
  - https://artifacthub.io/packages/helm/k8s-dashboard/kubernetes-dashboard

## firewall / required ports

If you have a firewall enabled, the following ports must be open:

### control-plane node

| Port | Protocol | Purpose |
|------|----------|----------|
| 6443 | TCP | Kubernetes API server |
| 2379-2380 | TCP | etcd server client API |
| 10250 | TCP | Kubelet API |
| 10259 | TCP | kube-scheduler |
| 10257 | TCP | kube-controller-manager |

### worker nodes

| Port | Protocol | Purpose |
|------|----------|----------|
| 10250 | TCP | Kubelet API |
| 10256 | TCP | kube-proxy |
| 30000-32767 | TCP | NodePort Services |

References:
- https://kubernetes.io/docs/reference/networking/ports-and-protocols/

## troubleshooting

### check service status

```
sudo systemctl status kubelet crio
```

### view kubelet logs

```
journalctl -xeu kubelet
```

### view cri-o logs

```
journalctl -xeu crio
```

### verify container runtime

```
sudo crictl info
```
- CRI-O socket path: `/var/run/crio/crio.sock`

### common errors

**"swap is enabled on the node"**
- Ensure swap is disabled: `sudo swapoff -a`
- For persistent disable, see [always running](#always-running) section

**"br_netfilter" or "overlay" module not loaded**
- Load the required modules:
  ```
  sudo modprobe br_netfilter
  sudo modprobe overlay
  ```
- For persistent loading, see [always running](#always-running) section

**"token is invalid" or "token has expired"**
- List existing tokens: `kubeadm token list`
- Create a new token: `kubeadm token create`
- Generate a new join command: `kubeadm token create --print-join-command`

**kubelet keeps crashing / CrashLoopBackOff**
- Check if container runtime is running: `sudo systemctl status crio`
- Check kubelet logs: `journalctl -xeu kubelet`
- Verify node is initialized: `kubectl get nodes`

**cannot connect to the cluster**
- Ensure kubeconfig is set up:
  ```
  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
  ```

## cleanup

### remove node

Cleanly shutdown and drain all containers/pods from the node:
```
kubectl drain <node name> --delete-emptydir-data --force --ignore-daemonsets
```

### reset kubernetes setup<sup>1</sup>

```
kubeadm reset
```

### clean up the rest of the configs<sup>1</sup>

```
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
ipvsadm -C
```

References:
- https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#tear-down

## notes

<sup>1</sup> Running this command requires elevated privileges (`sudo` or `su`).
