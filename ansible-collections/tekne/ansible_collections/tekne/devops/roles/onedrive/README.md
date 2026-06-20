# OneDrive Role

Installs and configures OneDrive client (abraunegg fork) for all users defined in ansible-role-user.

## What It Does

1. **Installs OneDrive package** (onedrive-abraunegg)
2. **Creates config directory** (`~/.config/onedrive`) for each user
3. **Creates sync directory** (`~/OneDrive`) for each user
4. **Copies config file** to each user's config directory
5. **Verifies installation** and configuration

## Requirements

- `community.general` collection (for `pacman` module)
- `ansible-role-user` must run before this role (provides `users` variable)

```bash
ansible-galaxy collection install community.general
```

## Role Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `onedrive_package` | `onedrive-abraunegg` | OneDrive package to install |
| `onedrive_sync_dir` | `OneDrive` | Sync directory name in home |
| `onedrive_config_dir` | `.config/onedrive` | Config directory in home |

## Files Deployed

| Source | Destination | Mode |
|--------|-------------|------|
| `files/onedrive` | `~/.config/onedrive/config` | 0600 |

## Directories Created

For each user:
- `~/.config/onedrive/` (mode 0700)
- `~/OneDrive/` (mode 0700)

## Dependencies

- **ansible-role-user**: Provides the `users` list for per-user configuration

## Example Playbook

```yaml
- hosts: workstations
  roles:
    - ansible-role-user      # Creates users first
    - ansible-role-onedrive  # Configures OneDrive for those users
```

## Tags

| Tag | Description |
|-----|-------------|
| `onedrive` | All OneDrive tasks |
| `packages` | Package installation only |
| `directories` | /var/log/onedrive and per-user dirs |
| `config` | Config file and directory creation |
| `verify` | Verification tasks |

## Post-Installation

After running the role, each user needs to authenticate:

```bash
onedrive --synchronize --single-directory
```

## License

MIT-0

## Author

dvaliente
