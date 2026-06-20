# Gaming Role

Installs gaming packages (Steam, Lutris, Wine, etc.) and configures a game launcher script for running games in a dedicated X session.

## What It Does

1. **Installs gaming packages** (19 packages including Steam, Lutris, Wine, fonts)
2. **Copies game.conf** to `/etc/security/limits.d/` (X configuration for gaming)
3. **Copies game script** to `/usr/local/bin/` (executable game launcher)
4. **Verifies installation** of all packages and files

## Requirements

- `community.general` collection (for `pacman` module)

```bash
ansible-galaxy collection install community.general
```

## Role Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `gaming_packages` | See defaults | List of gaming packages |
| `gaming_limits_conf_dest` | `/etc/security/limits.d/game.conf` | Destination for X config |
| `gaming_script_dest` | `/usr/local/bin/game` | Destination for game script |

### Packages Installed

**Game Launchers:**
- lutris, heroic-games-launcher, steam

**Wine Stack:**
- wine-tkg-clean-staging-git, winetricks, wine-gecko, wine-mono

**Proton/Gaming:**
- gamemode, proton-ge-custom-bin, openbox

**Fonts:**
- ttf-liberation, noto-fonts, noto-fonts-cjk, noto-fonts-emoji, ttf-ms-win10-auto

**Libraries:**
- lib32-systemd, lib32-gst-plugins-base, lib32-gst-plugins-good, lib32-pcsclite

## Files Deployed

| Source | Destination | Mode |
|--------|-------------|------|
| `files/game.conf` | `/etc/security/limits.d/game.conf` | 0644 |
| `files/game` | `/usr/local/bin/game` | 0755 |

## Game Script Usage

The `game` script launches games in a dedicated X session:

```bash
game steam
game lutris
```

## Example Playbook

```yaml
- hosts: gaming-pc
  roles:
    - ansible-role-gaming
```

## Tags

| Tag | Description |
|-----|-------------|
| `gaming` | All gaming tasks |
| `network` | Network connectivity wait (before packages) |
| `packages` | Package installation only |
| `config` | game.conf and game script deployment |
| `verify` | Verification tasks |

## License

MIT-0

## Author

dvaliente
