# GPU Role

Installs GPU drivers based on hostname. NVIDIA drivers for the host matching `gpu_nvidia_hostname` (default **YUGEN**), Intel/Mesa drivers for all other hosts.

## What It Does

1. **Detects GPU type** based on hostname
2. **Installs appropriate drivers** (NVIDIA or Intel/Mesa)
3. **Verifies installation** of all packages

## Requirements

- `community.general` collection (for `pacman` module)
- GPU host check uses `ansible_hostname` (from gathered facts); no extra role required

```bash
ansible-galaxy collection install community.general
```

## Role Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `gpu_nvidia_hostname` | `YUGEN` | Hostname that uses NVIDIA GPU (case-insensitive) |
| `gpu_nvidia_packages` | See defaults | NVIDIA packages |
| `gpu_intel_packages` | See defaults | Intel/Mesa packages |

### NVIDIA Packages (yugen)

- lib32-opencl-nvidia-tkg, lib32-vulkan-icd-loader, lib32-nvidia-utils-tkg
- nvidia-open-dkms-tkg, nvidia-settings-tkg, opencl-nvidia-tkg
- vulkan-icd-loader, nvidia-utils-tkg

### Intel/Mesa Packages (other hosts)

- mesa, lib32-mesa, vulkan-intel, lib32-vulkan-intel

## Dependencies

None. The role uses `ansible_hostname` (from gathered facts). When the playbook sets `hostname`/`cached_hostname` (e.g. workstation playbook), ensure fact caching or pre_tasks run so hostname is consistent; the role compares `ansible_hostname` to `gpu_nvidia_hostname`.

## Example Playbook

```yaml
- hosts: workstations
  roles:
    - ansible-role-gpu   # Installs NVIDIA on host matching gpu_nvidia_hostname (default: YUGEN), Intel/Mesa otherwise
```

## Tags

| Tag | Description |
|-----|-------------|
| `gpu` | All GPU tasks |
| `config` | Configuration/detection |
| `nvidia` | NVIDIA specific tasks |
| `intel` | Intel/Mesa specific tasks |
| `packages` | Package installation |
| `verify` | Verification tasks |

## Host-Specific Behavior

| Hostname | GPU Type | Packages Installed |
|----------|----------|-------------------|
| YUGEN (default) | NVIDIA | 8 NVIDIA/TKG packages |
| Others | Intel/Mesa | 4 Mesa/Vulkan packages |

## License

MIT-0

## Author

dvaliente
