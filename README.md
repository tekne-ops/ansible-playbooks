# ansible-playbooks

Ansible playbooks, inventories, and installation scripts for provisioning and configuring Tekne infrastructure. This repo orchestrates host configuration by consuming roles from the companion [`ansible-collections`](../ansible-collections) repo (`tekne.devops` collection).

## What This Repo Does

- Defines **playbooks** that run on local workstations/servers or remote Kubernetes nodes
- Holds **inventories** for prod (localhost) and k8s cluster hosts
- Stores **encrypted secrets** in Ansible Vault (`vars/vault.yml`), loaded only by an explicit `include_vars`
- Provides **Arch Linux installation scripts** for fresh installs from the live ISO
- Runs **CI linting** via GitHub Actions (`ansible-lint`)

Roles live in `ansible-collections`; this repo wires them together and supplies host-specific variables.

## Repository Structure

```
ansible-playbooks/
├── ansible.cfg              # Defaults to the workstation inventory; host key checking on
├── requirements.yml         # Galaxy collection dependencies (standalone CI)
├── vars/
│   └── vault.yml            # Encrypted secrets, included explicitly by the playbooks
├── inventories/
│   ├── workstation/hosts.yml
│   ├── server/hosts.yml
│   ├── prod/hosts.yml       # Legacy localhost inventory, not the default
│   └── k8s/
│       ├── hosts.yml
│       └── group_vars/k8s_cluster.yml
├── install/                 # Arch live-ISO provisioning (not Ansible playbooks)
│   ├── arch-install.sh
│   ├── render_autoinstall.py
│   ├── efi.sh
│   ├── profiles/hosts.json
│   └── lib/tekne_profiles.py
├── playbooks/
│   ├── workstation.yml      # ASTER, YUGEN, KVM
│   ├── server.yml           # THEMIS
│   ├── main.yml             # Compatibility dispatcher
│   ├── k8s.yml
│   ├── workstation.sh
│   ├── server.sh
│   ├── consul.sh
│   ├── jenkins.sh
│   └── hermes.sh
└── .github/workflows/
    └── ansible-lint.yml
```

## Supported Host Profiles

| Hostname | Type | Description |
|----------|------|-------------|
| **ASTER** | Laptop | Dual NVMe (HOME), hybrid Intel+NVIDIA, max AC gaming / BAT save |
| **YUGEN** | Workstation | Triple NVMe (DOCKER+HOME), NVIDIA GPU (TKG), gaming-optimized |
| **THEMIS** | Server | Triple NVMe (DOCKER+CACHE), bridge (br0), Docker services |
| **KVM** | VM | vda BOOT/ROOT, vdb HOME |

Hostname is read from `/etc/hostname` at runtime. Each entrypoint asserts the hostname on every run, including `--tags` runs.

| Entrypoint | Inventory | Allowed hostnames |
|------------|-----------|-------------------|
| `playbooks/workstation.yml` | `inventories/workstation/hosts.yml` | ASTER, YUGEN, KVM |
| `playbooks/server.yml` | `inventories/server/hosts.yml` | THEMIS |
| `playbooks/main.yml` | default workstation inventory (`hosts: localhost`) | ASTER, YUGEN, KVM, THEMIS |

`main.yml` is a compatibility dispatcher: ASTER, YUGEN, and KVM get the workstation roles; THEMIS gets the server roles. Prefer the explicit entrypoint.

## Playbooks

### workstation.yml

Arch Linux workstation playbook. Runs on the `workstations` group with `connection: local` and `become: true` on the play.

**Role execution order:**

| # | Role | Tag | Purpose |
|---|------|-----|---------|
| 1 | `tekne.devops.user` | `user` | Users, SSH keys, sudoers, dotfiles |
| 2 | `tekne.devops.network` | `network-host` | systemd-networkd, WiFi, br0, connectivity wait |
| 3 | `tekne.devops.os` | `os` | Locale, NTP, mirrors, tekne repo clones |
| 4 | `tekne.devops.pipewire` | `pipewire` | PipeWire audio stack |
| 5 | `tekne.devops.gpu` | `gpu` | NVIDIA (YUGEN), hybrid Intel+NVIDIA (ASTER), or Intel/Mesa (KVM) |
| 6 | `tekne.devops.xfce4` | `xfce4` | XFCE4 desktop, LightDM, bluetooth |
| 7 | `tekne.devops.kde` | `kde` | KDE Plasma desktop |
| 8 | `tekne.devops.gaming` | `gaming` | Steam, Lutris, Wine, gamemode |
| 9 | `tekne.devops.onedrive` | `onedrive` | OneDrive client (abraunegg) |
| 10 | `tekne.devops.bootstrap` | `bootstrap` | OneDrive sync, symlinks, XFCE config |
| 11 | `tekne.devops.nftables` | `nftables` | Host-specific firewall rules |
| 12 | `tekne.devops.docker` | `docker-host` | Docker engine and `dockers` network (YUGEN) |
| 13 | `tekne.devops.libvirt` | `libvirt` | QEMU/KVM virtualization (YUGEN) |
| 14 | `tekne.devops.hermes` | `hermes` | AWS helper; also present on the server entrypoint |

The bootstrap role pauses for interactive OneDrive authentication on first run.

### server.yml

THEMIS server playbook. Runs on the `servers` group with `connection: local`.

| # | Role | Tag |
|---|------|-----|
| 1 | `tekne.devops.user` | `user` |
| 2 | `tekne.devops.network` | `network-host` |
| 3 | `tekne.devops.os` | `os` |
| 4 | `tekne.devops.gpu` | `gpu` |
| 5 | `tekne.devops.nftables` | `nftables` |
| 6 | `tekne.devops.docker` | `docker-host` |
| 7 | `tekne.devops.libvirt` | `libvirt` |
| 8 | `tekne.devops.haproxy` | `haproxy` |
| 9 | `tekne.devops.repotekne` | `repotekne` |
| 10 | `tekne.devops.gerbera` | `gerbera` |
| 11 | `tekne.devops.consul` | `consul` |
| 12 | `tekne.devops.jenkins` | `jenkins` |
| 13 | `tekne.devops.hermes` | `hermes` |

```bash
# From repo root. ansible.cfg selects the workstation inventory and enables host key checking.
# Become is set on the play, not in ansible.cfg.

# Workstation
ansible-playbook playbooks/workstation.yml -i inventories/workstation/hosts.yml --ask-vault-pass
./playbooks/workstation.sh

# Server (THEMIS)
ansible-playbook playbooks/server.yml -i inventories/server/hosts.yml --ask-vault-pass
./playbooks/server.sh

# Compatibility dispatcher (workstation roles, or server roles on THEMIS)
ansible-playbook playbooks/main.yml --ask-vault-pass

# Specific roles
ansible-playbook playbooks/workstation.yml -i inventories/workstation/hosts.yml --ask-vault-pass --tags "user,os,gpu"

# Dry run
ansible-playbook playbooks/workstation.yml -i inventories/workstation/hosts.yml --ask-vault-pass --check
```

### k8s.yml

Prepares Debian 13 Kubernetes nodes (kubelet, kubeadm, kubectl, containerd, Calico). Targets the `k8s_cluster` inventory group via SSH as `devops`.

```bash
ansible-playbook playbooks/k8s.yml -i inventories/k8s/hosts.yml
```

## Fresh Arch Linux Installation

### arch-install.sh

Per-host profiles with dry-run, resume-from-task, and vault integration. Host profiles live in `install/profiles/hosts.json`.

```bash
./install/arch-install.sh                    # auto-detect host
./install/arch-install.sh YUGEN              # force profile
./install/arch-install.sh --dry-run ASTER
./install/arch-install.sh --vault-password-file ~/.vault_pass THEMIS
```

After reboot, run `playbooks/workstation.sh` (ASTER, YUGEN), `playbooks/server.sh` (THEMIS), or the KVM `workstation.yml` command from `install/profiles/hosts.json`.

ASTER uses ext4 for `/` and XFS for `/home`. THEMIS, YUGEN, and KVM use F2FS for those volumes. `/boot` is VFAT on every host. The UKI includes Plymouth with the firmware logo theme, so the manufacturer logo stays up through boot and shutdown.

`install/render_autoinstall.py` renders an Ubuntu autoinstall template. It exits without writing a file while any `REPLACE_WITH_*` placeholder is unresolved. The rendered autoinstall file is not committed.

## Collection Dependencies

Install collections before running playbooks:

```bash
ansible-galaxy collection install -r requirements.yml -p "${HOME}/.ansible/collections"
```

Pass that path with `ANSIBLE_COLLECTIONS_PATH` when it should take precedence over `collections_path` in `ansible.cfg`. CI does this with a temporary directory.

`requirements.yml` installs `amazon.aws`, `community.general`, `community.docker`, `ansible.posix`, and `tekne.devops` from Git. That file is what CI runs, so a standalone checkout does not need a sibling `ansible-collections` directory.

For local development, `ansible.cfg` sets `collections_path = ../ansible-collections`. On the live ISO, `install/arch-install.sh` stages that tree and installs it from a generated `requirements-chroot.yml`.

## Vault

Secrets are stored in `vars/vault.yml` (Ansible Vault encrypted). Playbooks load that file with `include_vars`. It is not under `group_vars`, so `ansible-inventory --list` does not decrypt it.

**Required variables:**

| Variable | Description |
|----------|-------------|
| `user_password` | Default password hash for users |
| `root_password` | Root password hash (optional) |
| `os_wifi_passphrase` | ASTER WiFi passphrase |
| `git_token` | GitHub token used by the `os` role to clone private tekne repositories |
| `haproxy_ssl_pem` | Full PEM (cert + key) for tekne.sv TLS |

```bash
ansible-vault edit vars/vault.yml
ansible-vault view vars/vault.yml
```

## Requirements

- Arch Linux (workstation/server playbooks) or Debian 13 (k8s playbook)
- Python 3
- Ansible Core 2.19+
- Collections: `amazon.aws`, `community.general`, `community.docker`, `ansible.posix`, `tekne.devops`

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
