# Network Role

Configures systemd-networkd, THEMIS bridge (br0) and SSH drop-in, ASTER WiFi via iwd, and waits for outbound connectivity before later roles run.

## What It Does

1. **Workstation (ASTER, YUGEN)** – Deploys `80-wifi-station.network` and `89-ethernet.network`; enables systemd-networkd, resolved, acpid; ASTER also enables iwd/bluetooth/tlp/thermald and connects to WiFi.
2. **THEMIS** – Deploys `25-br0` netdev/network units and `sshd_config.d/ssh.conf`.
3. **Connectivity** – Flushes handlers and pings `archlinux.org` until reachable.

Run after `tekne.devops.os` locale setup and before roles that need network (mirrors, git clones).

## Variables

| Variable | Description |
|----------|-------------|
| `network_hostname` | Uppercase hostname for conditionals |
| `network_hostname_raw` | Case-sensitive hostname for `Host=` in network units |
| `network_config_hosts` | Hosts that receive WiFi/Ethernet units (vars: ASTER, YUGEN, KVM) |
| `network_wifi_ssid` | ASTER WiFi SSID (default `esher`) |
| `network_wifi_interface` | ASTER interface; empty = auto-detect first `wl*` |
| `network_wifi_passphrase` | ASTER passphrase; defaults from vault `os_wifi_passphrase` |

## Tags

| Tag | Description |
|-----|-------------|
| `network-host` | All host network tasks (systemd-networkd, WiFi, br0) |
| `wifi` | ASTER WiFi connect steps |

## Example

```yaml
- role: tekne.devops.network
  tags: [network-host]
```
