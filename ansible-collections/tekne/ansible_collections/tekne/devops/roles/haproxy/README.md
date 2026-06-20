Role Name
=========

HAProxy role: installs and runs HAProxy in Docker, fronting HTTPS for tekne.sv (consul, repo, jenkins).

Requirements
------------

- Docker (e.g. ansible-role-docker). HAProxy runs in a container on network `dockers` at 192.168.75.10.
- TLS certificate: you must provide the PEM (cert + key) via **Ansible Vault** or a **path on the controller** — see below.

Role Variables
--------------

| Variable | Description |
|----------|-------------|
| `haproxy_ssl_pem` | **(vault)** Full PEM content (private key + certificate). Set in the playbook vault file. |
| `haproxy_ssl_pem_path` | Path on the Ansible controller to the PEM file. Use `-e haproxy_ssl_pem_path=/path/to/tekne.sv.pem` when running the playbook. |

**SSL certificate (tekne.sv.pem):** The PEM contains a private key and must never be committed to the role or git.

- **Option 1 – Vault (recommended):** Add to the playbook’s vault file:
  ```yaml
  haproxy_ssl_pem: |
    -----BEGIN PRIVATE KEY-----
    ...
    -----END PRIVATE KEY-----
    -----BEGIN CERTIFICATE-----
    ...
    -----END CERTIFICATE-----
  ```
  Run the playbook with `--ask-vault-pass` (or `--vault-password-file`).

- **Option 2 – Path on controller:** Keep the PEM only on your machine and pass its path when running the playbook:
  ```bash
  ansible-playbook main.yml -e haproxy_ssl_pem_path=/secure/location/tekne.sv.pem --ask-vault-pass
  ```
  The role copies the file from the controller to the target; it is not stored in the role or in version control.

If you previously had `files/tekne.sv.pem` in this role, remove it from the repo and add its content to the vault (or use the path option). The role’s `.gitignore` excludes `*.pem` so the file is not committed again.

Dependencies
------------

- ansible-role-docker (for Docker and the `dockers` network).

Example Playbook
----------------

    - hosts: servers
      vars_files:
        - vault   # vault contains haproxy_ssl_pem for server runs
      roles:
        - role: ansible-role-haproxy
          tags: haproxy

License
-------

BSD

Author Information
------------------

Optional.
