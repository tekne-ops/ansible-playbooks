# nftables configuration procedure for Docker on a clean install

This avoids the issues we hit: DNS timeouts, ping not working, and drops caused by **rule order** (drop before accept) and **missing return path** (no `oifname` for Docker bridges).

## Principles

1. **Order matters.** All `accept` rules must come **before** the final `drop` in the `forward` chain.
2. **Both directions.** Allow traffic **from** Docker bridges (containers → internet) **and** **to** Docker bridges (replies and any traffic to containers).
3. **Uplink.** If your default route uses a bridge (e.g. `br0`), allow forward to/from that interface as well.

## One-time setup (clean install)

### 1. Ensure the table and chain exist

If you already have `inet filter` with a `forward` chain (e.g. from another config), skip to step 2.

```bash
# Create table and forward chain if they don't exist
sudo nft add table inet filter
sudo nft add chain inet filter forward '{ type filter hook forward priority filter; policy accept; }'
```

### 2. Fix rule order: no drop before accept

If your existing `forward` chain has a `drop` at the **beginning**, remove it so we can add it at the **end**:

```bash
# List rules with handles
sudo nft -a list chain inet filter forward

# Delete the early "drop" rule (use the handle number from the output)
sudo nft delete rule inet filter forward handle <HANDLE>
```

### 3. Load the forward rules (accepts first, drop last)

**Option A – Use the provided config file**

From the repo root:

```bash
# Flush current forward rules so we start clean
sudo nft flush chain inet filter forward

# Load rules (the file uses "add rule" so the chain must exist)
sudo nft -f nftables-docker-forward.conf
```

**Option B – Run commands by hand**

Run in this order (all accepts, then one drop at the end):

```bash
sudo nft flush chain inet filter forward

# From containers (outbound)
sudo nft add rule inet filter forward iifname "docker0" accept
sudo nft add rule inet filter forward iifname "br-*" accept

# To containers (return traffic: ping, DNS, etc.)
sudo nft add rule inet filter forward oifname "docker0" accept
sudo nft add rule inet filter forward oifname "br-*" accept

# If your default route is via br0 (host uplink)
sudo nft add rule inet filter forward oifname "br0" accept
sudo nft add rule inet filter forward iifname "br0" accept

# Optional: explicit path Docker bridge → br0
sudo nft add rule inet filter forward iifname "br-*" oifname "br0" accept

# Then drop everything else
sudo nft add rule inet filter forward drop
```

### 4. Persist the configuration

Copy your working ruleset into the config that your system loads on boot (e.g. `/etc/nftables.conf` or a file under `/etc/nftables.d/`), and ensure the **forward** chain is defined with **accept rules before the drop**.

To dump the current ruleset:

```bash
sudo nft list ruleset
```

To dump only the inet filter table:

```bash
sudo nft list table inet filter
```

Merge the `forward` chain (with the correct order) into your main nftables config so it is applied at boot.

### 5. Optional: raw table and container IP

If you use a raw rule that drops traffic to the container IP (e.g. 172.20.0.13) when it doesn’t come from the Docker bridge, that can block NAT return traffic. Either:

- Omit that rule, or  
- Restrict it so it does **not** drop established/related (NATed) return traffic (e.g. match only non‑established or specific source interfaces).  

After any change, test from a container:

```bash
ping -c 2 8.8.8.8
dig +short google.com
```

## Quick reference: forward chain order

| Order | Rule | Purpose |
|------|------|--------|
| 1..N | `iifname "docker0" accept` / `iifname "br-*" accept` | Traffic **from** Docker (outbound) |
| N+1..M | `oifname "docker0" accept` / `oifname "br-*" accept` | Traffic **to** Docker (replies, ping, DNS) |
| M+1..K | `oifname "br0" accept` / `iifname "br0" accept` | Uplink (if default route is br0) |
| Last | `drop` | Drop everything else |

Never put `drop` before these accept rules.
