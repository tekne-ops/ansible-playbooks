#!/usr/bin/env python3
"""Load Tekne host install profiles from install/profiles/hosts.json (single source of truth)."""

from __future__ import annotations

import argparse
import json
import shlex
import sys
from copy import deepcopy
from pathlib import Path
from typing import Any

PROFILES_FILE = Path(__file__).resolve().parent.parent / "profiles" / "hosts.json"


def load_profiles(path: Path | None = None) -> dict[str, Any]:
    profile_path = path or PROFILES_FILE
    with open(profile_path, encoding="utf-8") as fh:
        data = json.load(fh)
    if "hosts" not in data or "global" not in data:
        raise ValueError(f"Invalid profile file (expected global + hosts): {profile_path}")
    return data


def valid_hosts(data: dict[str, Any] | None = None) -> tuple[str, ...]:
    data = data or load_profiles()
    return tuple(sorted(data["hosts"].keys()))


def host_profile(hostname: str, data: dict[str, Any] | None = None) -> dict[str, Any]:
    data = data or load_profiles()
    host = hostname.upper()
    if host not in data["hosts"]:
        valid = ", ".join(valid_hosts(data))
        raise ValueError(f"Unknown host {host!r}. Valid: {valid}")
    profile = deepcopy(data["hosts"][host])
    profile["hostname"] = host
    return profile


def global_config(data: dict[str, Any] | None = None) -> dict[str, Any]:
    data = data or load_profiles()
    return deepcopy(data["global"])


def pacstrap_base_packages(data: dict[str, Any] | None = None) -> list[str]:
    return list(global_config(data)["pacstrap_base_packages"])


def _bash_assoc(name: str, mapping: dict[str, str]) -> str:
    """Global associative array (declare -gA) so eval from load_host_profiles survives function return."""
    lines = [f"declare -gA {name}=("]
    for key in sorted(mapping):
        lines.append(f"  [{key}]={shlex.quote(mapping[key])}")
    lines.append(")")
    return "\n".join(lines)


def shell_init(data: dict[str, Any] | None = None) -> str:
    """Emit bash declarations for arch-install.sh."""
    data = data or load_profiles()
    g = data["global"]
    hosts = data["hosts"]

    role: dict[str, str] = {}
    disk0: dict[str, str] = {}
    disk1: dict[str, str] = {}
    disk2: dict[str, str] = {}
    disk2_layout: dict[str, str] = {}
    disk2_mount: dict[str, str] = {}
    disk2_start_mib: dict[str, str] = {}
    storage: dict[str, str] = {}
    layout: dict[str, str] = {}
    kernel: dict[str, str] = {}
    mcode: dict[str, str] = {}
    efi_extra: dict[str, str] = {}
    efi_intel: dict[str, str] = {}

    for name, profile in hosts.items():
        role[name] = profile["role"]
        disk0[name] = profile["disk0"]
        disk1[name] = profile["disk1"]
        if profile.get("disk2"):
            disk2[name] = profile["disk2"]
            disk2_layout[name] = profile.get("disk2_layout", "home")
            disk2_mount[name] = profile.get("disk2_mount", "/home")
            disk2_start_mib[name] = str(profile.get("disk2_start_mib", 1))
        storage[name] = profile["storage_kind"]
        layout[name] = profile["disk1_layout"]
        kernel[name] = profile["kernel_suffix"]
        mcode[name] = " ".join(profile["mcode_packages"])
        efi_extra[name] = profile.get("efi_extra", "")
        efi_intel[name] = profile.get("efi_intel", "")

    parts = [
        _bash_assoc("HOST_ROLE", role),
        _bash_assoc("HOST_DISK0", disk0),
        _bash_assoc("HOST_DISK1", disk1),
        _bash_assoc("HOST_DISK2", disk2),
        _bash_assoc("HOST_DISK2_LAYOUT", disk2_layout),
        _bash_assoc("HOST_DISK2_MOUNT", disk2_mount),
        _bash_assoc("HOST_DISK2_START_MIB", disk2_start_mib),
        _bash_assoc("HOST_STORAGE_KIND", storage),
        _bash_assoc("HOST_DISK1_LAYOUT", layout),
        _bash_assoc("HOST_KERNEL", kernel),
        _bash_assoc("HOST_MCODE", mcode),
        _bash_assoc("HOST_EFI_EXTRA", efi_extra),
        _bash_assoc("HOST_EFI_INTEL", efi_intel),
        f'declare -gra PACSTRAP_BASE_PKGS=({" ".join(shlex.quote(p) for p in g["pacstrap_base_packages"])})',
        f'declare -gra VALID_HOSTS=({" ".join(shlex.quote(h) for h in valid_hosts(data))})',
        f'declare -gr F2FS_MNT_OPTS={shlex.quote(g["f2fs_mount_opts"])}',
        f'declare -gr F2FS_MKFS_OPTS={shlex.quote(g["f2fs_mkfs_opts"])}',
        f'declare -gr ESP_SIZE_MIB={g["esp_size_mib"]}',
        f'declare -gr TIMEZONE={shlex.quote(g["timezone"])}',
        f'declare -gr THEMIS_BINARIES_REPO={shlex.quote(g["themis_binaries_repo"])}',
        f'declare -gr THEMIS_BINARIES_ROOT={shlex.quote(g["themis_binaries_root"])}',
    ]
    return "\n".join(parts)


def main() -> int:
    parser = argparse.ArgumentParser(description="Tekne install host profiles")
    parser.add_argument(
        "--shell-init",
        action="store_true",
        help="Print bash variable declarations for arch-install.sh",
    )
    parser.add_argument(
        "--profiles-file",
        type=Path,
        default=PROFILES_FILE,
        help="Path to hosts.json",
    )
    parser.add_argument("hostname", nargs="?", help="Print one host profile as JSON")
    args = parser.parse_args()

    data = load_profiles(args.profiles_file)

    if args.shell_init:
        print(shell_init(data))
        return 0

    if args.hostname:
        print(json.dumps(host_profile(args.hostname, data), indent=2))
        return 0

    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
