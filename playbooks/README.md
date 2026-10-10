# Playbooks

Entrypoints that run `tekne.devops` roles on a Tekne host. Host profiles, vault variables, and the Arch installer are documented in the repository [README](../README.md).

## Entrypoints

| File | Inventory | Hosts |
|------|-----------|-------|
| `workstation.yml` | `inventories/workstation/hosts.yml` | ASTER, YUGEN, KVM |
| `server.yml` | `inventories/server/hosts.yml` | THEMIS |
| `main.yml` | workstation inventory | ASTER, YUGEN, KVM, THEMIS |
| `k8s.yml` | `inventories/k8s/hosts.yml` | Debian Kubernetes nodes |

`main.yml` is a compatibility dispatcher. ASTER, YUGEN, and KVM get the workstation roles. THEMIS gets the server roles. Prefer `workstation.yml` or `server.yml`.

Every entrypoint checks `/etc/hostname` before the selected roles run, including `--tags` runs.

## Wrappers

| Script | What it runs |
|--------|----------------|
| `workstation.sh` | Playbook, inventory, and tags from `install/profiles/hosts.json` for the current host |
| `workstation-aster.sh` | `workstation.sh` when `/etc/hostname` is ASTER |
| `workstation-yugen.sh` | `workstation.sh` when `/etc/hostname` is YUGEN |
| `server.sh` | `workstation.sh` when `/etc/hostname` is THEMIS |
| `onedrive-auth.sh` | `onedrive-auth.yml`, the interactive Microsoft device login |
| `consul.sh` | `server.yml` tag `consul` on THEMIS |
| `jenkins.sh` | `server.yml` tag `jenkins` on THEMIS |
| `hermes.sh` | tag `hermes` on the workstation or server playbook for the current host |

Wrappers run `ansible-playbook` as the login user. Plays still set `become: true`. Tag lists live in `install/profiles/hosts.json` under `maintenance_tags`. Capability flags live in `inventories/host_profiles/`.

## Workstation role order

| # | Role | Tag |
|---|------|-----|
| 1 | `tekne.devops.user` | `user` |
| 2 | `tekne.devops.network` | `network-host` |
| 3 | `tekne.devops.os` | `os` |
| 4 | `tekne.devops.pipewire` | `pipewire` |
| 5 | `tekne.devops.gpu` | `gpu` |
| 6 | `tekne.devops.xfce4` | `xfce4` |
| 7 | `tekne.devops.kde` | `kde` |
| 8 | `tekne.devops.gaming` | `gaming` |
| 9 | `tekne.devops.onedrive` | `onedrive` |
| 10 | `tekne.devops.bootstrap` | `bootstrap` |
| 11 | `tekne.devops.nftables` | `nftables` |
| 12 | `tekne.devops.docker` | `docker-host` |
| 13 | `tekne.devops.libvirt` | `libvirt` |
| 14 | `tekne.devops.hermes` | `hermes` |

GPU selection is NVIDIA on YUGEN, hybrid Intel plus NVIDIA on ASTER, and Intel/Mesa on KVM. LightDM is installed for ASTER and YUGEN. The bootstrap role pauses for OneDrive authentication on the first sync, then runs `/srv/code/tekne/bash/bin/restore-cursor`.

## Server role order

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

The `n8n` role exists in `tekne.devops` and is not part of this playbook.

## Usage

```bash
ansible-playbook playbooks/workstation.yml -i inventories/workstation/hosts.yml --ask-vault-pass
./playbooks/workstation.sh

ansible-playbook playbooks/server.yml -i inventories/server/hosts.yml --ask-vault-pass
./playbooks/server.sh

ansible-playbook playbooks/workstation.yml -i inventories/workstation/hosts.yml --ask-vault-pass --tags "user,os,gpu"
ansible-playbook playbooks/k8s.yml -i inventories/k8s/hosts.yml
```

Shared tasks live in `tasks/`: hostname check, vault load, workstation monitor facts, and the two role lists.
