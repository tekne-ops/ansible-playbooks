#!/bin/bash
set -euo pipefail

# efibootmgr --create --disk /dev/nvme0n1 --part 1 --create --label "BOOT" --loader "/vmlinuz-linux-tkg-aster" --unicode " root=LABEL=ROOT rw initrd=\\intel-ucode.img initrd=\\initramfs-linux-tkg-aster.img kernel.split_lock_mitigate=0 split_lock_detect=off nowatchdog mitigations=off quiet loglevel=2 systemd.show_status=false rd.udev.log_level=2"
efibootmgr --create --disk /dev/nvme0n1 --part 1 --create --label "BOOT" --loader "\\EFI\\Linux\\arch-linux-tkg-aster.efi" --unicode