## readme

### prerequisites

1. Install `gpg`
   - This must be installed before adding the Kubernetes package repositories.
3. Edit `update-k8s-repos.sh` and make sure `K8S_VERSION` reflects the most current version of Kubernetes
   - You can find the most recent version at https://kubernetes.io/releases/.
   - Note that this script will add repositories for:
     - Kubernetes
     - CRI-O
4. Run `update-k8s-repos.sh` with elevated privileges (`sudo` or `su`)
   - This will download the public signing key for the package repositories listed above.
   - And also add the package repositories to the deb sources.

### install k8s

I used a few different sources to get the right combination of install that work for me. I chose to **not** use Kubernete's install script available in their docs. Source links are down below.

1. Install `kubeadm`, `kubectl`, and `kubelet` packages

Credit:
- https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
- https://www.webhi.com/how-to/setup-configure-kubernetes-on-ubuntu-debian-and-centos-rhel/

### install cri-o

1. Install `cri-o

### configure k8s

If your install is to have k8s always running, then you must permanently disable swap. This is typically disabled in `/etc/fstab`, `systemd.swap`, etc.
