# ansible-playbooks

Ansible playbooks, inventories, and installation scripts for provisioning and configuring Tekne infrastructure. This repo orchestrates host configuration by consuming roles from the companion [`ansible-collections`](../ansible-collections) repo (`tekne.devops` collection).

## What This Repo Does

- Defines **playbooks** that run on local workstations/servers or remote Kubernetes nodes
- Holds **inventories** for prod (localhost) and k8s cluster hosts
- Stores **encrypted secrets** in Ansible Vault (`group_vars/all/vault`)
- Provides **Arch Linux installation scripts** for fresh installs from the live ISO
- Runs **CI linting** via GitHub Actions (`ansible-lint`)

Roles live in `ansible-collections`; this repo wires them together and supplies host-specific variables.

## Repository Structure

```
ansible-playbooks/
├── ansible.cfg              # Single Ansible config (inventory, collections_path, callbacks)
├── requirements.yml         # Galaxy collection dependencies
├── group_vars/
│   └── all/
│       └── vault            # Encrypted secrets (passwords, TLS PEM, WiFi passphrase)
├── inventories/
│   ├── prod/hosts.yml       # Localhost inventory for workstation/server playbooks
│   └── k8s/
│       ├── hosts.yml        # k8s-mstr00 + k8s-node* hosts
│       └── group_vars/k8s_cluster.yml
├── install/                 # Arch live-ISO provisioning (not Ansible playbooks)
│   ├── arch-install.sh      # Arch installer with per-host profiles
│   ├── efi.sh               # EFI boot entry helper
│   ├── profiles/
│   │   └── hosts.json       # Single source for host disks, packages, kernel
│   └── lib/
│       ├── tekne_profiles.py
│       └── generate_archinstall_config.py
├── playbooks/
│   ├── main.yml             # Primary host configuration playbook
│   ├── k8s.yml              # Kubernetes node prerequisites (Debian)
│   ├── workstation.sh       # Tag-filtered workstation run
│   ├── server.sh            # Tag-filtered server run
│   ├── consul.sh            # Run consul role only
│   └── jenkins.sh           # Run jenkins role only
└── .github/workflows/
    └── ansible-lint.yml     # Lint on push/PR
```

## Supported Host Profiles

| Hostname | Type | Description |
|----------|------|-------------|
| **ASTER** | Laptop | Single NVMe, WiFi (iwd), Intel GPU, LightDM |
| **YUGEN** | Workstation | Triple NVMe, NVIDIA GPU (TKG), gaming-optimized |
| **THEMIS** | Server | Dual NVMe, bridge (br0), Docker services, no desktop |
| **KVM** | VM | vda BOOT/ROOT, vdb HOME |

Hostname is read from `/etc/hostname` at runtime; `main.yml` asserts it matches a known profile.

## Playbooks

### main.yml

Primary playbook for Arch Linux workstations and servers. Runs on `localhost` with `connection: local`.

**Role execution order:**

| # | Role | Tag | Purpose |
|---|------|-----|---------|
| 1 | `tekne.devops.user` | `user` | Users, SSH keys, sudoers, dotfiles |
| 2 | `tekne.devops.network` | `network-host` | systemd-networkd, WiFi, br0, connectivity wait |
| 3 | `tekne.devops.os` | `os` | Locale, NTP, mirrors, tekne repo clones |
| 4 | `tekne.devops.pipewire` | `pipewire` | PipeWire audio stack |
| 5 | `tekne.devops.gpu` | `gpu` | NVIDIA (YUGEN) or Intel/Mesa drivers |
| 6 | `tekne.devops.xfce4` | `xfce4` | XFCE4 desktop, LightDM, bluetooth |
| 7 | `tekne.devops.gaming` | `gaming` | Steam, Lutris, Wine, gamemode |
| 8 | `tekne.devops.onedrive` | `onedrive` | OneDrive client (abraunegg) |
| 9 | `tekne.devops.bootstrap` | `bootstrap` | OneDrive sync, symlinks, XFCE config |
| 10 | `tekne.devops.nftables` | `nftables` | Host-specific firewall rules |
| 11 | `tekne.devops.docker` | `docker-host` | Docker engine and `dockers` network |
| 12 | `tekne.devops.libvirt` | `libvirt` | QEMU/KVM virtualization |
| 13 | `tekne.devops.haproxy` | `haproxy` | HAProxy TLS reverse proxy (tekne.sv) |
| 14 | `tekne.devops.repotekne` | `repotekne` | Arch package repo container |
| 15 | `tekne.devops.gerbera` | `gerbera` | UPnP/DLNA media server |
| 16 | `tekne.devops.consul` | `consul` | HashiCorp Consul service mesh |
| 17 | `tekne.devops.jenkins` | `jenkins` | Jenkins CI container |

The bootstrap role pauses for interactive OneDrive authentication on first run.

```bash
# From repo root (ansible.cfg sets inventory and collections_path)

# Full run
ansible-playbook playbooks/main.yml --ask-vault-pass

# Workstation subset
./playbooks/workstation.sh

# Server subset (Docker services, libvirt, HAProxy, etc.)
./playbooks/server.sh

# Specific roles
ansible-playbook playbooks/main.yml --ask-vault-pass --tags "user,os,gpu"

# Dry run
ansible-playbook playbooks/main.yml --ask-vault-pass --check
```

### k8s.yml

Prepares Debian 13 Kubernetes nodes (kubelet, kubeadm, kubectl, containerd, Calico). Targets the `k8s_cluster` inventory group via SSH as `devops`.

```bash
ansible-playbook playbooks/k8s.yml -i inventories/k8s/hosts.yml
```

## Fresh Arch Linux Installation

Two installer scripts are available from the live ISO:

### arch-install.sh (recommended)

Per-host profiles with dry-run, resume-from-task, and vault integration. Host profiles live in `install/profiles/hosts.json`.

```bash
./install/arch-install.sh                    # auto-detect host
./install/arch-install.sh YUGEN              # force profile
./install/arch-install.sh --dry-run ASTER
./install/arch-install.sh --vault-password-file ~/.vault_pass THEMIS
```

After reboot, run `main.yml` from the installed system.

## Collection Dependencies

Install collections before running playbooks:

```bash
ansible-galaxy collection install -r requirements.yml
```

`requirements.yml` pulls `community.general`, `ansible.posix`, and the local `tekne.devops` collection. For local development, `ansible.cfg` sets `collections_path = ../ansible-collections` (resolves `tekne/devops/`). On the live ISO, the collection is mounted at `/media/ansible-collections/tekne/devops`.

For CI or fresh clones without a local collection tree, uncomment the Git source in `requirements.yml`:

```yaml
- name: git+https://github.com/tekne-ops/ansible-collections.git#/tekne/devops
  type: git
  version: main
```

## Vault

Secrets are stored in `group_vars/all/vault` (Ansible Vault encrypted).

**Required variables:**

| Variable | Description |
|----------|-------------|
| `user_password` | Default password hash for users |
| `root_password` | Root password hash (optional) |
| `os_wifi_passphrase` | ASTER WiFi passphrase |
| `haproxy_ssl_pem` | Full PEM (cert + key) for tekne.sv TLS |

```bash
ansible-vault edit group_vars/all/vault
ansible-vault view group_vars/all/vault
```

## Requirements

- Arch Linux (workstation/server playbooks) or Debian 13 (k8s playbook)
- Python 3
- Ansible Core 2.14+
- Collections: `community.general`, `ansible.posix`, `tekne.devops`

```bash
pacman -S ansible-core ansible
ansible-galaxy collection install -r requirements.yml
```

## Related Repos

| Repo | Purpose |
|------|---------|
| [`ansible-collections`](../ansible-collections) | `tekne.devops` Ansible collection with all roles |

## License

MIT-0

## Author

dvaliente
