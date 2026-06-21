#!/usr/bin/env python3
"""
Generate archinstall --config JSON for Tekne host profiles (ASTER, YUGEN, THEMIS, KVM).

Profiles mirror ansible-playbooks/playbooks/arch-install.sh (pacstrap, disks, packages).
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

# ---------------------------------------------------------------------------
# Host profile data (keep in sync with arch-install.sh)
# ---------------------------------------------------------------------------

ESP_SIZE_MIB = 1024
# Reserve space at disk end for backup GPT header + alignment (archinstall validates gpt_end).
GPT_TAIL_RESERVE_MIB = 4
TIMEZONE = "America/El_Salvador"
F2FS_MOUNT_OPTS = [
    "compress_algorithm=zstd:6",
    "compress_chksum",
    "atgc",
    "gc_merge",
    "lazytime",
]

PACSTRAP_BASE_PKGS = [
    "base", "base-devel", "intel-ucode",
    "linux-firmware", "linux-firmware-broadcom", "linux-firmware-liquidio",
    "linux-firmware-mellanox", "linux-firmware-nfp", "linux-firmware-qlogic",
    "dosfstools", "f2fs-tools", "exfatprogs",
    "python311", "python-pip", "python-pipx", "python-passlib", "python-pipenv",
    "ansible-core", "ansible-lint", "ansible",
    "blesh-git", "pikaur", "schedtoold",
    "vim", "vim-tagbar", "vim-tabular", "vim-syntastic", "vim-supertab",
    "vim-spell-es", "vim-spell-en", "vim-nerdtree", "vim-nerdcommenter",
    "vim-devicons", "vim-ansible",
    "mlocate", "bash-completion", "pkgfile", "efibootmgr", "acpi", "acpid",
    "iwd", "wpa_supplicant", "wireless-regdb", "rsync", "git", "wget", "reflector",
    "iptables-nft", "less", "usb_modeswitch", "libsecret", "gzip", "tar", "zlib", "xz",
    "nvme-cli", "openssh", "openssl", "screen", "sudo", "gnupg", "bind", "cronie",
    "inetutils", "whois", "zip", "unzip", "p7zip", "sed", "fuse", "mdadm", "jq",
    "curl", "make", "pkg-config", "dbus", "openbsd-netcat", "irqbalance", "schedtool",
    "shfmt", "gsmartcontrol", "shellcheck", "bats", "cpupower", "devtools",
    "fakechroot", "fakeroot", "tcpdump", "parted", "xfsprogs", "libsmbios", "fwupd",
    "pipewire", "pipewire-alsa", "pipewire-jack", "pipewire-pulse", "wireplumber",
    "alsa-utils", "wmctrl", "man", "udisks2", "restic", "noto-fonts",
    "noto-fonts-emoji", "ttf-dejavu", "ttf-liberation", "ttf-ms-win10-auto",
    "systemd", "ukify",
]

HOST_PROFILES: dict[str, dict[str, Any]] = {
    "THEMIS": {
        "role": "server",
        "disk0_ctrl": "/dev/nvme0",
        "disk1_ctrl": "/dev/nvme1",
        "disk1_layout": "docker",
        "disk1_mount": "/var/lib/docker",
        "disk1_start_mib": 0,
        "kernel_pkg": "linux-tkg-themis",
        "mcode_packages": [
            "mesa", "lib32-mesa", "vulkan-intel", "lib32-vulkan-intel",
        ],
        "additional_repositories": [],
        "custom_repositories": [
            {
                "name": "local-repo",
                "url": "file:///tmp/binaries/themis",
                "sign_check": "Optional",
                "sign_option": "TrustAll",
            },
            {
                "name": "tekne",
                "url": "http://repo.tekne.sv/$arch",
                "sign_check": "Optional",
                "sign_option": "TrustAll",
            },
        ],
        "services": ["sshd.service", "systemd-networkd.service", "systemd-resolved.service"],
    },
    "ASTER": {
        "role": "laptop",
        "disk0_ctrl": "/dev/nvme0",
        "disk1_ctrl": "/dev/nvme1",
        "disk1_layout": "home",
        "disk1_mount": "/home",
        "disk1_start_mib": 1,
        "kernel_pkg": "linux-tkg-aster",
        "mcode_packages": [
            "mesa", "lib32-mesa", "vulkan-intel", "lib32-vulkan-intel", "xorg-server",
            "lib32-opencl-nvidia-tkg", "lib32-vulkan-icd-loader", "lib32-nvidia-utils-tkg",
            "nvidia-open-dkms-tkg", "nvidia-settings-tkg", "opencl-nvidia-tkg",
            "vulkan-icd-loader", "nvidia-utils-tkg", "sof-firmware", "upd72020x-fw",
            "wd719x-firmware", "ast-firmware", "aic94xx-firmware", "brightnessctl",
            "libinput", "thermald", "tlp", "tlpui", "pipewire-audio", "libldac", "libfreeaptx",
        ],
        "additional_repositories": ["multilib"],
        "custom_repositories": [
            {
                "name": "tekne",
                "url": "http://repo.tekne.sv/$arch",
                "sign_check": "Optional",
                "sign_option": "TrustAll",
            },
        ],
        "services": [
            "systemd-networkd.service", "systemd-resolved.service", "acpid.service",
            "iwd.service", "bluetooth.service", "thermald.service", "tlp.service",
        ],
    },
    "YUGEN": {
        "role": "pc",
        "disk0_ctrl": "/dev/nvme0",
        "disk1_ctrl": "/dev/nvme1",
        "disk1_layout": "docker",
        "disk1_mount": "/var/lib/docker",
        "disk1_start_mib": 0,
        "kernel_pkg": "linux-tkg-yugen",
        "mcode_packages": [
            "lib32-opencl-nvidia", "lib32-vulkan-icd-loader", "lib32-nvidia-utils",
            "nvidia-open-dkms-tkg", "nvidia-settings-tkg", "opencl-nvidia-tkg",
            "vulkan-icd-loader", "nvidia-utils-tkg", "sound-theme-smooth",
            "upd72020x-fw", "wd719x-firmware", "ast-firmware", "aic94xx-firmware",
        ],
        "additional_repositories": ["multilib"],
        "custom_repositories": [
            {
                "name": "tekne",
                "url": "http://repo.tekne.sv/$arch",
                "sign_check": "Optional",
                "sign_option": "TrustAll",
            },
        ],
        "services": [
            "systemd-networkd.service", "systemd-resolved.service", "acpid.service",
        ],
    },
    "KVM": {
        "role": "vm",
        "disk0_ctrl": "/dev/vda",
        "disk1_ctrl": "/dev/vdb",
        "disk1_layout": "home",
        "disk1_mount": "/home",
        "disk1_start_mib": 1,
        "kernel_pkg": "linux-tkg-themis",
        "mcode_packages": [
            "mesa", "lib32-mesa", "vulkan-intel", "lib32-vulkan-intel",
        ],
        "additional_repositories": ["multilib"],
        "custom_repositories": [
            {
                "name": "tekne",
                "url": "http://repo.tekne.sv/$arch",
                "sign_check": "Optional",
                "sign_option": "TrustAll",
            },
        ],
        "services": [
            "systemd-networkd.service", "systemd-resolved.service", "acpid.service",
        ],
    },
}

VALID_HOSTS = tuple(HOST_PROFILES.keys())


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
    rem = disk_mib - start_mib - GPT_TAIL_RESERVE_MIB
    if rem < 64:
        raise ValueError(
            f"Disk too small ({disk_mib} MiB): need >{start_mib + GPT_TAIL_RESERVE_MIB + 64} MiB "
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
    part = _partition_base()
    part.update({
        # esp + boot: archinstall get_efi_partition() / get_boot_partition() (matches parted "set 1 esp on")
        "flags": ["boot", "esp"],
        "fs_type": "fat32",
        "size": _size_mib(ESP_SIZE_MIB),
        "start": _size_mib(1),
        "mountpoint": "/boot",
    })
    return part


def _partition_f2fs(mountpoint: str, start_mib: int, size_mib: int) -> dict[str, Any]:
    part = _partition_base()
    part.update({
        "flags": [],
        "fs_type": "f2fs",
        "start": _size_mib(start_mib),
        "mount_options": F2FS_MOUNT_OPTS.copy(),
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
    root_start = ESP_SIZE_MIB + 1
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
    pkgs = list(PACSTRAP_BASE_PKGS)
    pkgs.extend(profile["mcode_packages"])
    pkgs.append(f"{kernel}-headers")
    # Kernel itself is installed via the top-level "kernels" config key.
    # Preserve order, drop duplicates
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
    host = hostname.upper()
    if host not in HOST_PROFILES:
        raise ValueError(f"Unknown host {host!r}. Valid: {', '.join(VALID_HOSTS)}")

    profile = HOST_PROFILES[host]
    kernel = profile["kernel_pkg"]

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
        "hostname": host,
        "timezone": TIMEZONE,
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
    parser = argparse.ArgumentParser(
        description="Generate archinstall config.json for Tekne hosts (ASTER, YUGEN, THEMIS, KVM)",
    )
    parser.add_argument("hostname", choices=VALID_HOSTS, help="Host profile name")
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
