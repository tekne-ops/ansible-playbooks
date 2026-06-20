# Hostname Role

Captures the hostname from `/etc/hostname` on the remote host and caches it as a persistent fact for use by other roles.

## What It Does

1. **Checks** if `cached_hostname` is already in `ansible_facts` (e.g. from fact cache or a previous play).
2. **If not cached:** reads `/etc/hostname` via `slurp`, then sets `cached_hostname` (cacheable fact) from the file contents (trimmed).
3. **Sets** `hostname` to `cached_hostname` or falls back to `ansible_hostname` for convenience.

Use this role when other roles need a stable hostname that matches `/etc/hostname` (e.g. for host-specific package or config choices). With fact caching enabled, `cached_hostname` persists across plays.

## Requirements

Fact caching must be enabled in `ansible.cfg`:

```ini
[defaults]
gathering = smart
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible_facts_cache
fact_caching_timeout = 86400
```

## Provided Variables

| Variable | Description |
|----------|-------------|
| `hostname` | The hostname (set each run) |
| `ansible_facts['cached_hostname']` | Cached hostname (persists across plays) |

## Example Playbook

```yaml
- hosts: servers
  roles:
    - ansible-role-hostname
    - other-role-that-needs-hostname

# In other-role-that-needs-hostname/tasks/main.yml:
# - name: Use hostname
#   ansible.builtin.debug:
#     msg: "Host is {{ hostname }}"
```

## Tags

| Tag | Description |
|-----|-------------|
| `hostname` | All tasks in this role |
| `always` | Cache check and variable setting |

## License

MIT-0

## Author

dvaliente
