# Pipewire Role

Installs and configures Pipewire audio system for Arch Linux, replacing conflicting audio packages.

## What It Does

1. **Removes conflicting packages** (jack, ffmpeg, jack2, etc.)
2. **Installs Pipewire stack** (pipewire, wireplumber, pavucontrol, etc.)
3. **Creates user config directories** for each user from ansible-role-user
4. **Deploys configuration files** to user directories
5. **Enables user service** (without starting it)
6. **Verifies installation** and service state

## Requirements

- `community.general` collection (for `pacman` module)
- `ansible-role-user` must run before this role (provides `users` variable)

```bash
ansible-galaxy collection install community.general
```

## Role Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `pipewire_conflicting_packages` | See defaults | Packages to remove before install |
| `pipewire_packages` | See defaults | Pipewire packages to install |
| `pipewire_user_service` | `pipewire` | User service to enable |

### Conflicting Packages (removed)

- jack, ffmpeg, jack2, libjack, portaudio, libopenmpt, freerdp

### Pipewire Packages (installed)

- pipewire, pipewire-audio, pipewire-libcamera, pipewire-jack
- pipewire-alsa, pipewire-pulse, lib32-pipewire, lib32-pipewire-jack
- wireplumber, pavucontrol, sound-theme-smooth

## Dependencies

- **ansible-role-user**: Provides the `users` list for per-user configuration

## Files

| Source | Destination |
|--------|-------------|
| `files/pipewire.conf` | `~/.config/pipewire/pipewire.conf` |
| `files/sink-eq06-sony.conf` | `~/.config/pipewire/pipewire.conf.d/sink-eq06.conf` |

## Created Directories

For each user:
- `~/.config/wireplumber/wireplumber.conf.d/`
- `~/.config/pipewire/pipewire.conf.d/`

## Example Playbook

```yaml
- hosts: workstations
  roles:
    - ansible-role-user      # Must run first
    - ansible-role-pipewire
```

## Tags

| Tag | Description |
|-----|-------------|
| `pipewire` | All pipewire tasks |
| `network` | Network connectivity wait (before packages) |
| `packages` | Package install/remove only |
| `config` | Configuration directories and files |
| `service` | User service management |
| `verify` | Verification tasks |

## License

MIT-0

## Author

dvaliente
