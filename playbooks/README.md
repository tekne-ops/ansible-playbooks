# Tekne Ansible

Operational entrypoints are documented in the repository [README](../README.md). Use `workstation.yml` with `inventories/workstation/hosts.yml` for ASTER, YUGEN, and KVM. Use `server.yml` with `inventories/server/hosts.yml` for THEMIS. `main.yml` dispatches to those role sets after a hostname check that always runs.

Ansible automation for provisioning and configuring Arch Linux workstations and servers.

## Repository Structure

```
ansible/
├── ansible-playbook/
│   └── archlinux/          # Arch Linux playbooks and scripts
│       ├── ansible.cfg     # Ansible configuration
│       ├── inventory.yml   # Localhost inventory
│       ├── vault           # Encrypted secrets (passwords)
│       ├── main.yml # Main playbook
│       ├── prep.sh         # Installation preparation script
│       └── roles/          # Downloaded roles (created by prep.sh)
├── roles/                  # Ansible roles (individual git repos)
│   ├── ansible-role-os/
│   ├── ansible-role-user/
│   ├── ansible-role-gaming/
│   ├── ansible-role-gpu/
│   ├── ansible-role-onedrive/
│   ├── ansible-role-pipewire/
│   ├── ansible-role-xfce4/
│   └── ansible-role-hostname/
├── sync.sh                 # Sync script for all role repos
├── push.sh                 # Legacy push script
└── roles.sh                # Clone all roles from GitHub
```

## Supported Hosts

| Hostname | Type | Description |
|----------|------|-------------|
| **ASTER** | Laptop | Single NVMe, WiFi, Intel GPU |
| **YUGEN** | Workstation | Triple NVMe, NVIDIA GPU |
| **THEMIS** | Server | Dual NVMe |
| **HEPHAESTUS** | Workstation | SDA + RAID |

## Quick Start

### 1. Fresh Arch Linux Installation

Boot from Arch Linux ISO and run:

```bash
# Download and run prep script
curl -O https://raw.githubusercontent.com/dvaliente-tekne/ansible-playbook/main/archlinux/prep.sh
chmod +x prep.sh
./prep.sh YUGEN  # Replace with your hostname
```

The prep script will:
- Connect to WiFi (if applicable)
- Download required Ansible roles
- Format and partition drives
- Install base system with pacstrap
- Configure bootloader and chroot

### 2. Post-Installation Configuration

After rebooting into the new system:

```bash
cd /path/to/ansible-playbook/archlinux

# Run the workstation playbook
ansible-playbook playbooks/workstation.yml -i inventories/workstation/hosts.yml --ask-vault-pass
```

## Playbooks

See **../README.md** for full playbook documentation (pre-tasks, role order, tags, usage).

### main.yml

Configures ASTER and YUGEN workstations with full desktop environment. Runs on `localhost`; hostname must be ASTER or YUGEN (enforced in pre_tasks).

**Roles executed (in order):**
1. `ansible-role-user` - Users, SSH keys, sudoers, dotfiles
2. `ansible-role-os` - Locale, NTP, mirrors, network
3. `ansible-role-pipewire` - PipeWire audio configuration
4. `ansible-role-gpu` - NVIDIA or Intel/Mesa drivers
5. `ansible-role-xfce4` - XFCE4 desktop, LightDM (ASTER), bluetooth
6. `ansible-role-gaming` - Steam, Lutris, Wine, gamemode
7. `ansible-role-onedrive` - OneDrive client installation and setup
8. `ansible-role-bootstrap` - OneDrive sync (interactive), symlinks, XFCE config

**Usage:**
```bash
# Full run
ansible-playbook playbooks/workstation.yml -i inventories/workstation/hosts.yml --ask-vault-pass

# Run specific roles
ansible-playbook playbooks/workstation.yml -i inventories/workstation/hosts.yml --ask-vault-pass --tags "user,os"

# Dry run
ansible-playbook playbooks/workstation.yml -i inventories/workstation/hosts.yml --ask-vault-pass --check

# Verbose output
ansible-playbook playbooks/workstation.yml -i inventories/workstation/hosts.yml --ask-vault-pass -vv
```

## Roles

| Role | Description |
|------|-------------|
| **ansible-role-os** | System config: locale, NTP, mirrors, network (systemd-networkd) |
| **ansible-role-user** | User accounts, SSH keys, sudoers, home directories, dotfiles |
| **ansible-role-gpu** | GPU drivers: NVIDIA (YUGEN) or Intel/Mesa (others) |
| **ansible-role-gaming** | Steam, Lutris, Wine, Proton, gaming fonts |
| **ansible-role-onedrive** | OneDrive client (abraunegg fork) |
| **ansible-role-pipewire** | PipeWire audio with EQ configuration |
| **ansible-role-xfce4** | XFCE4 desktop, themes, LightDM (ASTER only) |
| **ansible-role-hostname** | Hostname caching for role dependencies |

## Vault

Secrets are stored in `vault` file encrypted with Ansible Vault.

**Required variables:**
- `user_password` - Default password for users (hashed)
- `root_password` - Root password (optional)
- `haproxy_ssl_pem` - (When using haproxy role on server) Full PEM content (cert + key) for tekne.sv TLS. Keep in vault; do not commit the PEM file.

**Managing vault:**
```bash
# Edit vault
ansible-vault edit vault

# View vault contents
ansible-vault view vault

# Re-encrypt with new password
ansible-vault rekey vault
```

## sync.sh - Role Management

Manage all role repositories at once:

```bash
# Check status of all repos
./sync.sh status

# Pull latest changes
./sync.sh pull

# Push all changes
./sync.sh push

# Push with custom commit message
COMMIT_MSG='feat: added network config' ./sync.sh push

# Full sync (pull then push)
./sync.sh sync

# Clone all ansible-role repos from GitHub
./sync.sh clone
```

## prep.sh - Installation Script

Automates Arch Linux installation from the live ISO.

**Features:**
- Host-specific drive configuration
- NVMe formatting with optimal settings
- F2FS filesystem with compression
- Automatic WiFi connection
- Downloads Ansible roles from GitHub
- Installs base system with pacstrap
- Configures EFI boot entry

**Usage:**
```bash
./prep.sh <hostname>
./prep.sh YUGEN
./prep.sh ASTER
```

## Host-Specific Configuration

### ASTER (Laptop)
- WiFi enabled (connects to "esher")
- Intel GPU (Mesa drivers)
- LightDM display manager
- Single NVMe drive

### YUGEN (Workstation)
- No WiFi (Ethernet only)
- NVIDIA GPU (TKG drivers)
- Triple NVMe drives
- Gaming-optimized

### THEMIS (Server)
- Minimal configuration
- No desktop environment
- Dual NVMe drives

### HEPHAESTUS (Workstation)
- SDA + RAID configuration
- Intel GPU
- mdadm RAID support

## Requirements

- Arch Linux (or Arch-based distribution)
- Python 3
- Ansible Core 2.14+
- `community.general` collection

```bash
# Install Ansible
pacman -S ansible-core ansible

# Install required collection
ansible-galaxy collection install community.general
```

## License

MIT-0

## Author

dvaliente
