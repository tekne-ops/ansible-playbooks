#!/usr/bin/env python3
"""
Generate archinstall --config JSON for Tekne host profiles (ASTER, YUGEN, THEMIS, KVM).

Host profiles: install/profiles/hosts.json (single source of truth).
See: https://archinstall.archlinux.page/installing/guided.html
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import uuid
from copy import deepcopy
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from tekne_profiles import global_config, host_profile, load_profiles, valid_hosts

# ---------------------------------------------------------------------------
# archinstall layout helpers
# ---------------------------------------------------------------------------


def _global() -> dict[str, Any]:
    return global_config()


def _uid() -> str:
    return str(uuid.uuid4())


def _sector_size() -> dict[str, Any]:
    """archinstall >=2.8 (py3.14 ISO) requires sector_size object, not null."""
    return {"value": 512, "unit": "B"}


def _size_mib(value: int) -> dict[str, Any]:
    return {"sector_size": _sector_size(), "unit": "MiB", "value": value}


def disk_size_mib(device: str) -> int:
    """Query block device size in MiB (live ISO / install host)."""
    path = Path(device)
    if not path.is_block_device():
        raise ValueError(f"Block device not found: {device}")
    proc = subprocess.run(
        ["blockdev", "--getsize64", device],
        check=True,
        capture_output=True,
        text=True,
    )
    return int(proc.stdout.strip()) // (1024 * 1024)


def remaining_partition_mib(disk_mib: int, start_mib: int) -> int:
    """MiB for a partition from start_mib to near disk end (no Percent unit)."""
    g = _global()
    tail = g["gpt_tail_reserve_mib"]
    rem = disk_mib - start_mib - tail
    if rem < 64:
        raise ValueError(
            f"Disk too small ({disk_mib} MiB): need >{start_mib + tail + 64} MiB "
            f"for partition starting at {start_mib} MiB",
        )
    return rem


def _partition_base() -> dict[str, Any]:
    """Fields required by archinstall on current ISO (py3.14)."""
    return {
        "btrfs": [],
        "dev_path": None,
        "mount_options": [],
        "obj_id": _uid(),
        "status": "create",
        "type": "primary",
    }


def _partition_esp() -> dict[str, Any]:
    g = _global()
    part = _partition_base()
    part.update({
        "flags": ["boot", "esp"],
        "fs_type": "fat32",
        "size": _size_mib(g["esp_size_mib"]),
        "start": _size_mib(1),
        "mountpoint": "/boot",
    })
    return part


def _partition_f2fs(mountpoint: str, start_mib: int, size_mib: int) -> dict[str, Any]:
    g = _global()
    part = _partition_base()
    part.update({
        "flags": [],
        "fs_type": "f2fs",
        "start": _size_mib(start_mib),
        "mount_options": g["f2fs_mount_options"].copy(),
        "mountpoint": mountpoint,
        "size": _size_mib(size_mib),
    })
    return part


def build_disk_config(
    disk0: str,
    disk1: str,
    disk1_mount: str,
    disk1_start_mib: int,
) -> dict[str, Any]:
    """Two-disk layout: disk0 = ESP + ROOT, disk1 = HOME or DOCKER."""
    g = _global()
    root_start = g["esp_size_mib"] + 1
    disk0_mib = disk_size_mib(disk0)
    disk1_mib = disk_size_mib(disk1)
    root_size_mib = remaining_partition_mib(disk0_mib, root_start)
    disk1_size_mib = remaining_partition_mib(disk1_mib, disk1_start_mib)
    return {
        "config_type": "manual_partitioning",
        "device_modifications": [
            {
                "device": disk0,
                "wipe": True,
                "partitions": [
                    _partition_esp(),
                    _partition_f2fs("/", root_start, root_size_mib),
                ],
            },
            {
                "device": disk1,
                "wipe": True,
                "partitions": [
                    _partition_f2fs(disk1_mount, disk1_start_mib, disk1_size_mib),
                ],
            },
        ],
    }


def build_packages(profile: dict[str, Any]) -> list[str]:
    kernel = profile["kernel_pkg"]
    pkgs = list(_global()["pacstrap_base_packages"])
    pkgs.extend(profile["mcode_packages"])
    pkgs.append(f"{kernel}-headers")
    seen: set[str] = set()
    out: list[str] = []
    for pkg in pkgs:
        if pkg not in seen:
            seen.add(pkg)
            out.append(pkg)
    return out


def build_config(
    hostname: str,
    disk0: str,
    disk1: str,
    *,
    archinstall_version: str = "2.8.6",
    mountpoint: str = "/mnt",
    silent: bool = True,
) -> dict[str, Any]:
    profile = host_profile(hostname)
    kernel = profile["kernel_pkg"]
    g = _global()

    mirror_config: dict[str, Any] = {
        "mirror_regions": {
            "United States": [],
        },
        "optional_repositories": [],
        "custom_repositories": deepcopy(profile["custom_repositories"]),
    }

    config: dict[str, Any] = {
        "version": archinstall_version,
        "script": "guided",
        "silent": silent,
        "debug": False,
        "offline": False,
        "no_pkg_lookups": True,
        "archinstall-language": "English",
        "hostname": profile["hostname"],
        "timezone": g["timezone"],
        "ntp": True,
        "additional-repositories": profile["additional_repositories"],
        "audio_config": {"audio": "pipewire"},
        "bootloader_config": {
            "bootloader": "Systemd-boot",
            "uki": False,
            "removable": False,
        },
        "kernels": [kernel],
        "packages": build_packages(profile),
        "locale_config": {
            "kb_layout": "us",
            "sys_enc": "UTF-8",
            "sys_lang": "en_US",
        },
        "mirror_config": mirror_config,
        "network_config": {},
        "profile_config": None,
        "disk_config": build_disk_config(
            disk0,
            disk1,
            profile["disk1_mount"],
            profile["disk1_start_mib"],
        ),
        "swap": {"enabled": False},
        "services": profile["services"],
        "pacman_config": {
            "color": False,
            "parallel_downloads": 5,
        },
        "custom_commands": [],
    }

    if mountpoint:
        config["disk_config"]["mountpoint"] = mountpoint

    return config


def validate_config(config: dict[str, Any]) -> None:
    """Ensure disk_config matches archinstall on current ISO (py3.14)."""
    disk = config.get("disk_config") or {}
    has_esp = False
    for dm in disk.get("device_modifications") or []:
        for idx, part in enumerate(dm.get("partitions") or []):
            if "dev_path" not in part:
                raise ValueError(
                    f"partition[{idx}] missing 'dev_path' — update generate_archinstall_config.py",
                )
            flags = part.get("flags") or []
            if "esp" in flags and part.get("mountpoint"):
                has_esp = True
            for key in ("start", "size"):
                size = part.get(key)
                if not isinstance(size, dict) or size.get("sector_size") is None:
                    raise ValueError(
                        f"partition[{idx}].{key} missing sector_size object "
                        f"— update generate_archinstall_config.py",
                    )
                if size.get("unit") == "Percent":
                    raise ValueError(
                        f"partition[{idx}].{key} uses Percent (unsupported on current archinstall); "
                        f"use MiB from disk size",
                    )
    if not has_esp:
        raise ValueError(
            "disk_config has no ESP partition (flags must include 'esp' with a mountpoint)",
        )


def build_creds_template(root_password: str | None = None) -> dict[str, Any]:
    """Creds file for archinstall --creds (passwords kept separate from config)."""
    creds: dict[str, Any] = {}
    if root_password:
        creds["root_enc_password"] = root_password
    return creds


def main() -> int:
    hosts = valid_hosts()
    parser = argparse.ArgumentParser(
        description="Generate archinstall config.json for Tekne hosts (ASTER, YUGEN, THEMIS, KVM)",
    )
    parser.add_argument("hostname", choices=hosts, help="Host profile name")
    parser.add_argument("--disk0", required=True, help="Disk0 block device (e.g. /dev/nvme0n1)")
    parser.add_argument("--disk1", required=True, help="Disk1 block device (e.g. /dev/nvme1n1)")
    parser.add_argument(
        "--output-dir",
        default=".",
        help="Directory for config.json (and creds.json if --root-password set)",
    )
    parser.add_argument(
        "--mountpoint",
        default="/mnt",
        help="archinstall install mountpoint (must match TEKNE_INSTALL_ROOT)",
    )
    parser.add_argument(
        "--archinstall-version",
        default="2.8.6",
        help="archinstall config version string",
    )
    parser.add_argument(
        "--root-password",
        help="Plain-text root password for creds.json (optional; Ansible user role runs in task 9)",
    )
    parser.add_argument(
        "--interactive",
        action="store_true",
        help="Set silent=false in config (archinstall TUI prompts)",
    )
    args = parser.parse_args()

    # Ensure profiles file is readable before building config.
    load_profiles()

    config = build_config(
        args.hostname,
        args.disk0,
        args.disk1,
        archinstall_version=args.archinstall_version,
        mountpoint=args.mountpoint,
        silent=not args.interactive,
    )

    validate_config(config)

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    config_path = out_dir / "config.json"
    with open(config_path, "w", encoding="utf-8") as fh:
        json.dump(config, fh, indent=2)
        fh.write("\n")
    print(config_path, file=sys.stderr)

    if args.root_password:
        creds = build_creds_template(args.root_password)
        creds_path = out_dir / "creds.json"
        with open(creds_path, "w", encoding="utf-8") as fh:
            json.dump(creds, fh, indent=2)
            fh.write("\n")
        print(creds_path, file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
