## Readme

## prerequisites

Install `gpg`
- This must be installed before adding the Kubernetes package repositories.

Edit `update-k8s-repos.sh` and make sure `K8S_VERSION` reflects the most current version of Kubernetes
- You can find the most recent version at https://kubernetes.io/releases/.
- Note that this script will add repositories for:
  - Kubernetes
  - CRI-O

Run `update-k8s-repos.sh`<sup>1</sup>
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

## initialize control-plane node

```
kubeadm init --pod-network-cidr=<cidr>
```
- Example of a `<cidr>` is `192.168.0.0/16`
- Save the `kubeadm join` command from the `kubeadm init` output - this is the command to join additional nodes to your cluster
  - More info: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#tear-down
- This can be reset using `kubeadm reset` (alternatively, see [cleanup](#cleanup) section below)
  - More info: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#remove-the-node

## configure network policy

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
If your install is to have k8s always running, then you must permanently disable swap. This is typically disabled in `/etc/fstab`, `systemd.swap`, etc.

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
