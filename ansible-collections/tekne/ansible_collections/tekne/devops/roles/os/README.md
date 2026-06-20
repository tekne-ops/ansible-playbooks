# OS Role

Configures Arch Linux system settings: reflector (mirrors), locale, NTP, pacman mirrorlist, THEMIS services, and tekne repo clones.

Network configuration lives in **`tekne.devops.network`** (run with tag `network-host`).

## What It Does

1. **Reflector** – Ensures `/etc/xdg/reflector` exists and copies `reflector.conf`.
2. **Locale** – Sets `LANG` in `/etc/locale.conf`, uncomments locale in `/etc/locale.gen`, runs `locale-gen` (via handler).
3. **THEMIS services** – cronie, irqbalance, sshd (enable/start).
4. **NTP** – Enables NTP with `timedatectl set-ntp true`.
5. **Mirrors** – Runs reflector to update `/etc/pacman.d/mirrorlist`.
6. **Tekne repos** – Clones bash/python/ansible collections under `/srv/code/tekne` (requires network; run `network` role first).

## Handlers

| Handler | Description |
|---------|-------------|
| `Generate locales` | Runs `locale-gen` |
| `restart bluetooth` | Restarts bluetooth.service (for bootstrap role) |

## Tags

| Tag | Description |
|-----|-------------|
| `os` | All OS tasks |
| `system_config` | Reflector directory and config |
| `locale` | Locale settings and locale-gen |
| `ntp` | NTP enable |
| `mirrors` | Pacman mirrorlist via reflector |
| `themis_services` | THEMIS cronie/irqbalance/sshd |
| `tekne_bash` / `tekne_python` / `tekne_ansible` | Repo clones and PATH |

## License

MIT
