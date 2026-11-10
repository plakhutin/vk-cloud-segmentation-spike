#!/usr/bin/env bash
set -euo pipefail
# Run on each fresh Ubuntu 22.04 VM as root. Downloads use the configured proxy.
[[ ${EUID} == 0 ]] || { echo 'Run as root' >&2; exit 1; }
[[ $(. /etc/os-release; echo "$ID:$VERSION_ID") == ubuntu:22.04 ]] || { echo 'Ubuntu 22.04 required' >&2; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo 'amd64 required' >&2; exit 1; }
[[ $# == 1 && $1 == --install ]] || { echo "Usage: $0 --install" >&2; exit 1; }
for c in curl tar systemctl apt-get; do command -v "$c" >/dev/null || exit 1; done
# Pre-fetch versioned artifacts before changing the host.
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
curl -fsSL https://github.com/containerd/containerd/releases/download/v1.7.27/containerd-1.7.27-linux-amd64.tar.gz -o "$d/containerd.tgz"
curl -fsSL https://github.com/opencontainers/runc/releases/download/v1.2.6/runc.amd64 -o "$d/runc"
curl -fsSL https://github.com/containernetworking/plugins/releases/download/v1.6.2/cni-plugins-linux-amd64-v1.6.2.tgz -o "$d/cni.tgz"
curl -fsSL https://raw.githubusercontent.com/containerd/containerd/v1.7.27/containerd.service -o "$d/containerd.service"
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key -o "$d/kubernetes.key"
apt-get update
apt-get install -y apt-transport-https ca-certificates gpg
install -d -m 0755 /etc/apt/keyrings /opt/cni/bin /etc/containerd
cat "$d/kubernetes.key" | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet=1.31.14-1.1 kubeadm=1.31.14-1.1 kubectl=1.31.14-1.1
apt-mark hold kubelet kubeadm kubectl
tar -C /usr/local -xzf "$d/containerd.tgz"
install -m 0755 "$d/runc" /usr/local/sbin/runc
tar -C /opt/cni/bin -xzf "$d/cni.tgz"
install -m 0644 "$d/containerd.service" /etc/systemd/system/containerd.service
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
swapoff -a
sed -i '/^[^#].*\sswap\s/s/^/# spike: /' /etc/fstab
printf '%s\n' overlay br_netfilter > /etc/modules-load.d/k8s-spike.conf
modprobe overlay; modprobe br_netfilter
printf '%s\n' 'net.bridge.bridge-nf-call-iptables = 1' 'net.bridge.bridge-nf-call-ip6tables = 1' 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-k8s-spike.conf
sysctl --system
systemctl daemon-reload
systemctl enable --now containerd kubelet
