#!/bin/bash
set -euo pipefail

# === CONFIGURATION ===
ESP="/boot"                   # EFI System Partition mountpoint
BOOTLOADER_ID="BOOT"              # Folder under EFI/ to store grubx64.efi
GRUB_MODULES="all_video boot btrfs cat chain configfile echo efifwsetup efinet ext2 fat font gettext gfxmenu gfxterm gfxterm_background gzio halt help hfsplus iso9660 jpeg keystatus loadenv loopback linux ls lsefi lsefimmap lsefisystab lssal memdisk minicmd normal ntfs part_apple part_msdos part_gpt password_pbkdf2 png probe reboot regexp search search_fs_uuid search_fs_file search_label sleep smbios squash4 test true video xfs zfs zfscrypt zfsinfo play cpuid tpm cryptodisk gcry_rijndael gcry_sha256 luks lvm mdraid09 mdraid1x raid5rec raid6rec"

# SBAT file
SBAT_FILE="/usr/share/grub/sbat.csv"

# === SCRIPT START ===

echo "[*] Installing GRUB into EFI System Partition..."
grub-install \
  --target=x86_64-efi \
  --efi-directory="${ESP}" \
  --bootloader-id="${BOOTLOADER_ID}" \
  --modules="${GRUB_MODULES}" \
  --sbat "${SBAT_FILE}" \
  --disable-shim-lock

echo "[*] Signing grubx64.efi with sbctl..."
sbctl sign -s "${ESP}/EFI/${BOOTLOADER_ID}/grubx64.efi"

echo "[*] Copying signed GRUB to default BOOTX64.EFI..."
cp "${ESP}/EFI/${BOOTLOADER_ID}/grubx64.efi" "${ESP}/EFI/BOOT/BOOTX64.EFI"

echo "[*] Signing BOOTX64.EFI with sbctl..."
sbctl sign -s "${ESP}/EFI/BOOT/BOOTX64.EFI"

echo "[*] Generating grub.cfg..."
grub-mkconfig -o /boot/grub/grub.cfg

echo "[+] Done. You can now reboot and Secure Boot should accept GRUB."

