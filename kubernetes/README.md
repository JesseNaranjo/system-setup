## Readme

## prerequisites

1. Install `gpg`
   - This must be installed before adding the Kubernetes package repositories.
3. Edit `update-k8s-repos.sh` and make sure `K8S_VERSION` reflects the most current version of Kubernetes
   - You can find the most recent version at https://kubernetes.io/releases/.
   - Note that this script will add repositories for:
     - Kubernetes
     - CRI-O
4. Run `update-k8s-repos.sh`<sup>1</sup>
   - This will download the public signing key for the package repositories listed above.
   - And also add the package repositories to the deb sources.

## install k8s

I used a few different sources to get the right combination of install that work for me. I chose to **not** use Kubernete's install script available in their docs. Source links are down below.

1. Install `kubeadm`, `kubectl`, and `kubelet` packages
2. Start `kubelet` using `systemctl enable kubelet.service --now`<sup>1</sup>
   - Alternatively, skip this step and use `start-k8s.sh`<sup>1</sup>

Credit:
- https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
- https://www.webhi.com/how-to/setup-configure-kubernetes-on-ubuntu-debian-and-centos-rhel/

## install cri-o

1. Install `cri-o`
2. Start `crio` using `systemctl enable crio.service --now`<sup>1</sup>
   - Alternatively, skip this step and use `start-k8s.sh`<sup>1</sup>

## initialize control-plane node

1. `kubeadm init --pod-network-cidr=<cidr>`<sup>1</sup>
   - Example of a `<cidr>` is `192.168.0.0/16`
   - This can be reset using `kubeadm reset` - more info here:
     - https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#tear-down
     - https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#clean-up-the-control-plane
2. Save the `kubeadm join` command from the `kubeadm init` output - this is the command to join additional nodes to your cluster
   - More info: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#tear-down

## configure network policy

Steps:
1. `kubectl apply -f <add-on.yaml>` (add-on.yaml can be a local file or a URL)

Recommendations:
- Calico for small-scale pods, easy entry-level effort
  - YAML file should be available at https://github.com/projectcalico/calico/tree/master/manifests
  - https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises
- Cilium for large-scale pods, steep learning curve, uses eBPF
- Popular addons: https://kubernetes.io/docs/concepts/cluster-administration/addons/

Credit:
- https://www.reddit.com/r/kubernetes/comments/1110k8p/suggestions_for_k8s_cni/

## configure k8s

If your install is to have k8s always running, then you must permanently disable swap. This is typically disabled in `/etc/fstab`, `systemd.swap`, etc.

## notes

<sup>1</sup> Running this command requires elevated privileges (`sudo` or `su`).
