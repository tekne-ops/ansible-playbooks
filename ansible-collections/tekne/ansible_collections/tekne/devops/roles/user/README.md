# User Role

Manages system users, passwords, SSH authorized keys, sudoers, and home-directory configuration for Arch Linux.

## What It Does

1. **Validates** that `user_password` is defined (e.g. from vault).
2. **Creates users** from the `users` list (shell, group, groups, password).
3. **Sets root password** when `manage_root_password` is true.
4. **Configures SSH authorized keys** from role `files/` for each user with `ssh_key_file`.
5. **Deploys sudoers files** to `/etc/sudoers.d/` (e.g. `sudo_dvaliente`, `sudo_devops`).
6. **Creates home directories** (e.g. `.config/systemd/user`, `.gnupg`, `.ssh`, `bin`) and copies dotfiles (`.bashrc`, `.vimrc`, `pikaur.conf`).

## Requirements

- `ansible.posix` collection (for `authorized_key` module)

```bash
ansible-galaxy collection install ansible.posix
```

## Role Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `users` | See defaults | List of users to create |
| `default_shell` | `/bin/bash` | Default shell for users |
| `default_group` | `users` | Default primary group |
| `manage_root_password` | `true` | Whether to set root password |
| `user_directories` | See defaults | Directories to create in each user's home |
| `user_password` | **(vault)** | Default password hash for users (required) |
| `root_password` | **(vault)** | Root password hash (falls back to user_password) |

### User Object Properties

Each user in the `users` list supports:

| Property | Required | Default | Description |
|----------|----------|---------|-------------|
| `name` | Yes | - | Username |
| `groups` | Yes | - | Comma-separated secondary groups |
| `ssh_key_file` | No | - | Filename in role `files/` for authorized_keys |
| `shell` | No | `default_shell` | User's login shell |
| `group` | No | `default_group` | Primary group |
| `password` | No | `user_password` | User-specific password hash |
| `ssh_exclusive` | No | `true` | Replace all existing SSH keys |

### Default User Directories

Created in each user's home (mode 0755 except `.gnupg`/`.ssh` 0700):

- `.config/systemd/user`, `.config/autostart`, `.config/remmina`, `.config/pikaur.conf` (via copy)
- `.vim/autoload`, `.vim/bundle`, `.vim/colors`
- `bin`, `.gnupg`, `.ssh`

## Files Deployed

| Source (in role `files/`) | Destination | Mode |
|---------------------------|-------------|------|
| `bashrc` | `~/.bashrc` | 0644 |
| `vimrc` | `~/.vimrc` | 0644 |
| `pikaur.conf` | `~/.config/pikaur.conf` | 0644 |
| `sudo_dvaliente` | `/etc/sudoers.d/sudo_dvaliente` | 0440 |
| `sudo_devops` | `/etc/sudoers.d/sudo_devops` | 0440 |
| `<ssh_key_file>` | `~/.ssh/authorized_keys` (via authorized_key) | - |

Sudoers files are validated with `visudo -cf %s` before deployment.

## Example Playbook

```yaml
- hosts: localhost
  roles:
    - role: ansible-role-user
      vars:
        users:
          - name: admin
            groups: 'wheel,docker'
            ssh_key_file: admin
          - name: deploy
            groups: 'deploy'
            shell: /bin/zsh
```

## Tags

| Tag | Description |
|-----|-------------|
| `user` | All user tasks |
| `validation` | Variable validation only |
| `create` | User creation only |
| `root` | Root password management only |
| `ssh` | SSH key configuration only |
| `sudo` | Sudoers file deployment |
| `home_config` | Home directories and dotfiles |

## Security

Password hashes should be stored in an encrypted vault file:

```bash
ansible-vault create vault
# In vault: user_password: '$6$...'  (and optionally root_password)

ansible-playbook playbook.yml --ask-vault-pass
```

Generate password hashes with:

```bash
python3 -c "import crypt; print(crypt.crypt('password', crypt.mksalt(crypt.METHOD_SHA512)))"
```

## License

MIT

## Author

dvaliente
