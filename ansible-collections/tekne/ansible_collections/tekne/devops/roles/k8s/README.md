# k8s

Prepares Debian hosts for Kubernetes: apt prerequisites, `pkgs.k8s.io` repository (default **v1.36**), `kubelet` / `kubeadm` / `kubectl` (held), then upstream **containerd**, **runc**, and **CNI** binaries. **kubelet** and **containerd** are enabled but not started.

## Binary runtime (`tasks/containerd_runtime.yml`)

After kubelet is enabled, the role (by default):

1. Extracts [containerd v2.3.1](https://github.com/containerd/containerd/releases/download/v2.3.1/containerd-2.3.1-linux-amd64.tar.gz) under `/usr/local`
2. Installs the upstream [containerd.service](https://raw.githubusercontent.com/containerd/containerd/main/containerd.service) unit to `/usr/local/lib/systemd/system/containerd.service`
3. Runs `systemd` daemon-reload and enables `containerd` (does not start it)
4. Installs [runc v1.4.2](https://github.com/opencontainers/runc/releases/download/v1.4.2/runc.amd64) to `/usr/local/sbin/runc`
5. Extracts [CNI plugins v1.9.1](https://github.com/containernetworking/plugins/releases/download/v1.9.1/cni-plugins-linux-amd64-v1.9.1.tgz) into `/opt/cni/bin`
6. Writes `/usr/local/bin/containerd config default` to `/etc/containerd/config.toml`
7. Sets `SystemdCgroup = true` and inserts `sandbox_image = "registry.k8s.io/pause:3.10"` after `enable_tls_streaming`, then restarts `containerd`

Disable with `k8s_install_containerd_binary: false`. Versions and URLs are in `defaults/main.yml`.

## kubeadm init (`tasks/kubeadm_init.yml`)

On the control plane only, when `k8s_install_kubeadm_init: true` (default):

1. Runs `kubeadm init` if `/etc/kubernetes/admin.conf` is missing
2. Parses `--token` and `--discovery-token-ca-cert-hash` from init output (or `kubeadm token create --print-join-command` if already initialized) into host facts and `/root/kubeadm-join.facts.yml`
3. Configures `~/.kube/config` for `k8s_kube_config_user` (defaults to `ansible_user`, e.g. `devops`)

Worker joins can use:

```yaml
hostvars[groups['k8s_control_plane'][0]]['k8s_kubeadm_join_token']
hostvars[groups['k8s_control_plane'][0]]['k8s_kubeadm_discovery_token_ca_cert_hash']
```

## Calico (`tasks/calico.yml`)

Imported from `main.yml` immediately after **Initialize Kubernetes control plane**, when `k8s_install_calico: true` (default). Tagged `k8s-kubeadm` and `k8s-calico` so it runs with either tag filter after kubeadm init.

1. `kubectl apply -f` [tigera-operator.yaml](https://raw.githubusercontent.com/projectcalico/calico/v3.32.0/manifests/tigera-operator.yaml)
2. Wait until `kubectl get crds` lists `installations.operator.tigera.io` and `apiservers.operator.tigera.io`
3. `kubectl apply -f` [custom-resources.yaml](https://raw.githubusercontent.com/projectcalico/calico/v3.32.0/manifests/custom-resources.yaml)
4. Wait for `tigera-operator` pod Ready (non-fatal verification)

Apply custom-resources alone: `--tags k8s-calico-custom --limit k8s-mstr00`

Wait retries/delay: `k8s_calico_wait_retries` (30), `k8s_calico_wait_delay` (10s). Disable with `k8s_install_calico: false`.

## kubeadm join (`tasks/kubeadm_join.yml`)

On **worker** hosts only (`k8s_workers`), when `k8s_install_kubeadm_join: true` (default), after the control plane is initialized:

```bash
kubeadm join --token <token> <control-plane-host>:6443 --discovery-token-ca-cert-hash sha256:<hash>
```

- `<token>` and hash come from `hostvars[k8s_master_host]` (or `/root/kubeadm-join.facts.yml` on the master if workers are joined in a separate run)
- `<control-plane-host>` is the master `ansible_host` (default `192.168.122.216` for `k8s-mstr00`)
- Port: `k8s_control_plane_port` (default `6443`)

Skips nodes that already have `/etc/kubernetes/kubelet.conf`.

```bash
ansible-playbook playbooks/k8s.yml -i inventories/k8s/hosts.yml --tags k8s-kubeadm-join --limit k8s_workers
```

## Cluster verification (`tasks/cluster_verify.yml`)

Final step on the **control plane** (`k8s-mstr00`), when `k8s_run_cluster_verify: true` (default). Runs and prints:

- `kubectl get nodes -o wide`
- `kubectl get pods -A -o wide`
- `kubectl get pods -n calico-system -o wide`
- `kubectl get pods -n kube-system -l k8s-app=kube-dns`
- `kubectl get svc`
- `kubectl cluster-info`

```bash
ansible-playbook playbooks/k8s.yml -i inventories/k8s/hosts.yml --tags k8s-verify --limit k8s-mstr00
```

## Requirements

- Debian (tested target: Debian 13)
- Root or `become`
- Network access to `pkgs.k8s.io`, `github.com`, and `raw.githubusercontent.com`

## Example playbook

```yaml
- hosts: k8s_cluster
  become: true
  roles:
    - tekne.devops.k8s
```

```bash
ansible-playbook playbooks/k8s.yml -i inventories/k8s/hosts.yml
```

## Tags

- `k8s` — all tasks
- `k8s-apt` — repositories and cache
- `k8s-packages` — install and hold
- `k8s-containerd` — binary containerd, runc, CNI
- `k8s-services` — kubelet enable; containerd daemon-reload and enable
- `k8s-kubeadm` — control plane init and join token capture
- `k8s-kubeadm-join` — join worker nodes to the cluster
- `k8s-verify` — cluster health checks (control plane only)
- `k8s-kubeconfig` — admin kubeconfig for cluster user
- `k8s-calico` — Calico/Tigera operator (control plane only)
- `k8s-calico-custom` — apply Calico custom-resources only (master)
