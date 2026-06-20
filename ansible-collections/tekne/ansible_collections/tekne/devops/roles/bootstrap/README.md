# Bootstrap Role

Post-install bootstrap: installs extra packages, runs OneDrive first sync (with interactive auth), creates symlinks from OneDrive to home, configures Bluetooth, and applies XFCE desktop settings (wallpaper, themes, fonts, shortcuts).

## What It Does

**Execution order:**

1. **Network check** – Waits for connectivity (ping archlinux.org) before packages.
2. **Package installation** – Installs `bootstrap_packages` via pacman (e.g. Chrome, Zoom, VS Code, Cursor, gaming/office apps). Verifies installation.
3. **OneDrive sync** (`tasks/onedrive_sync.yml`) – If `~/.config/onedrive/items.sqlite3` does not exist: runs first sync in background, **pauses for user to authenticate** with Microsoft (URL + code), waits for sync to finish, then enables the user `onedrive.service` so sync runs on login.
4. **Symlinks** (`tasks/symlinks.yml`) – Ensures parent dirs exist; for each entry in `bootstrap_symlinks`, creates a symlink from OneDrive path to home path (only if source exists). Sets `.ssh` mode 0700 and SSH key permissions. Skips and warns when source is missing.
5. **Bluetooth** (`tasks/bluetooth.yml`) – When `/etc/bluetooth/main.conf` exists, applies `bootstrap_bluetooth_config` (lineinfile) and notifies `restart bluetooth`.
6. **XFCE** (`tasks/xfce.yml`) – Configures desktop for `bootstrap_user`: wallpaper per monitor, cursor/GTK/WM/icon themes, keyboard shortcuts (Super+t terminal, Super+b browser), workspace count, input/event sounds, font and RGBA. Uses `xfconf-query` with a fixed display/runtime (e.g. DISPLAY=:0, XDG_RUNTIME_DIR for UID 1000). Can depend on `xfce_display_available` (set by playbook/other role) for summary message.

## Requirements

- `ansible-role-user` run first (users exist).
- OneDrive client installed and configured (e.g. `ansible-role-onedrive`).
- For OneDrive sync: `bootstrap_user`, `bootstrap_onedrive_config_dir`, `bootstrap_onedrive_binary`; first sync is **interactive** (pause for auth).
- For XFCE: XFCE session and display (e.g. logged in or DISPLAY available); vars use hardcoded `dvaliente` and `/run/user/1000` in some shell commands.

## Role Variables

### defaults/main.yml

| Variable | Default | Description |
|----------|---------|-------------|
| `bootstrap_user` | `dvaliente` | User for OneDrive sync and XFCE config |
| `bootstrap_group` | `users` | User's group |
| `bootstrap_home` | `/home/{{ bootstrap_user }}` | Home directory |
| `bootstrap_onedrive` | `{{ bootstrap_home }}/OneDrive` | OneDrive sync directory |
| `bootstrap_onedrive_config_dir` | `{{ bootstrap_home }}/.config/onedrive` | OneDrive config dir (config file inside) |
| `bootstrap_onedrive_binary` | `/usr/bin/onedrive` | OneDrive binary |
| `bootstrap_onedrive_sync_options` | `--sync --download-only --verbose` | First sync options |
| `bootstrap_onedrive_sync_timeout` | `3600` | First sync timeout (seconds) |
| `bootstrap_bluetooth_name` | `{{ ansible_hostname \| default('BlueZ') }}` | Bluetooth device name |
| `bootstrap_xfce_wallpaper` | Path in Pictures/Wallpapers | Wallpaper image path |
| `bootstrap_xfce_monitors` | `eDP-1`, `DP-1-1` | Monitor names for wallpaper (override per host in playbook) |
| `bootstrap_xfce_cursor_theme` | `Bibata-Original-Amber` | Cursor theme |
| `bootstrap_xfce_wm_theme` | `minimal-grey2` | Window manager theme |
| `bootstrap_xfce_gtk_theme` | `Adwaita-dark` | GTK theme |
| `bootstrap_xfce_icon_theme` | `Flat-Remix-Cyan-Dark` | Icon theme |
| `bootstrap_xfce_font` | `Sans 11` | Default font |
| `bootstrap_xfce_monospace_font` | `Monospace 11` | Monospace font |
| `bootstrap_xfce_font_rgba` | `rgb` | Font RGBA |
| `bootstrap_xfce_workspace_count` | `1` | Workspace count |
| `bootstrap_xfce_skip_if_no_display` | `true` | Skip XFCE when no display (behavior may depend on `xfce_display_available`) |
| `bootstrap_packages` | See below | Pacman packages to install |

**Default `bootstrap_packages`:** google-chrome, zoom, ventoy-bin, visual-studio-code-bin, cursor-bin, proton-ge-custom-bin, teams-for-linux-bin, httpfs2-2gbplus, ttf-ms-win10-auto, heroic-games-launcher, crossover, deezer, wps-office, libtiff5, omnissa-horizon-client.

### vars/main.yml

- **OneDrive:** `bootstrap_onedrive_config_dir: "/home/dvaliente/.config/onedrive"` (fixed path for sync/service).
- **Symlinks:** `bootstrap_symlinks` – list of `src`/`dest` (and optional `mode` for SSH keys). Examples: Documents, Notes, bashrc, Remmina, SSH config/keys, Pictures, avatar (.face, .face.icon), `bin/asd` from OneDrive script.
- **SSH keys:** `bootstrap_ssh_keys` – paths and modes for key files (e.g. 0600 id_rsa, 0644 id_rsa.pub).
- **Bluetooth:** `bootstrap_bluetooth_config` – list of `regexp`/`line` for `/etc/bluetooth/main.conf` (Name, AutoEnable, SessionMode, StreamMode, NameResolving, MultiProfile, ControllerMode, FastConnectable, JustWorksRepairing).

## Task Files

| File | Purpose |
|------|---------|
| `main.yml` | Network wait, package install, include onedrive_sync, symlinks, bluetooth, xfce |
| `onedrive_sync.yml` | First sync (with pause for auth), enable user onedrive.service |
| `symlinks.yml` | Create symlinks from `bootstrap_symlinks`, fix SSH dir/key permissions |
| `bluetooth.yml` | lineinfile on `/etc/bluetooth/main.conf`, notify restart bluetooth |
| `xfce.yml` | xfconf-query for wallpaper, themes, shortcuts, workspaces, sounds, fonts |

## Handlers

The role notifies **`restart bluetooth`** after changing `/etc/bluetooth/main.conf`. Define this handler in the same playbook (e.g. `ansible-role-os` provides it when run before bootstrap).

## Symlinks (from vars)

Typical links (customize via `bootstrap_symlinks`): OneDrive/Documents → ~/Documents; Documents/notes → ~/.local/share/notes; bashrc.txt → ~/.bashrc; Remmina config; SSH config and keys; Pictures; avatar → .face / .face.icon; bin/asd from script.

## Tags

| Tag | Description |
|-----|-------------|
| `bootstrap` | All bootstrap tasks |
| `network` | Network wait |
| `packages` | Package install and verify |
| `onedrive` | OneDrive sync and service |
| `sync` | First sync and auth pause |
| `service` | OneDrive user service enable |
| `symlinks` | Symlink creation and SSH permissions |
| `ssh` | SSH dir and key permissions (inside symlinks) |
| `bluetooth` | Bluetooth config |
| `xfce` | XFCE desktop config |
| `wallpaper` | Wallpaper per monitor |
| `cursor` | Cursor theme |
| `theme` | WM/GTK/icon themes |
| `shortcuts` | Keyboard shortcuts |
| `workspaces` | Workspace count |
| `sounds` | Input/event sounds |
| `fonts` | Font and RGBA |
| `verify` | Package verification |

## Example Playbook

Playbook typically sets host-specific `bootstrap_xfce_monitors` (e.g. ASTER: eDP-1, DP-1-1; YUGEN: DP-1, DP-2, DP-3):

```yaml
- hosts: localhost
  roles:
    - ansible-role-user
    - ansible-role-onedrive
    - role: ansible-role-bootstrap
      vars:
        bootstrap_user: dvaliente
        bootstrap_xfce_monitors: ["DP-1", "DP-2", "DP-3"]  # YUGEN
```

## Notes

- **OneDrive first sync** pauses for user authentication; follow on-screen URL/code steps.
- Symlinks are created only when the **source** exists; missing sources are reported and skipped.
- XFCE tasks use `sudo -u dvaliente` and fixed `/run/user/1000` in places; for multiple users or UIDs, adjust templates or variables.
- Ensure a `restart bluetooth` handler exists in the playbook (e.g. from `ansible-role-os`).

## License

MIT-0

## Author

dvaliente
