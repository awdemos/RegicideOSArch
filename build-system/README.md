# RegicideOSArch Build System

## Overview

This directory contains the build infrastructure for RegicideOSArch, an Arch Linux-based variant of RegicideOS with COSMIC Desktop. The build uses Dagger as a reproducible orchestration layer and standard Arch tooling (`pacman`, `mkinitcpio`) inside a container to produce a bootable root filesystem.

## Architecture

```
build-system/
├── arch/
│   ├── build-qemu-image.sh            # LUKS + Btrfs + GRUB QCOW2 image builder (loop devices)
│   ├── build-qemu-image-guestfish.sh  # Pure guestfish/systemd-boot QCOW2 builder (no loop devices)
│   ├── build-qemu-image-guestmount.sh # FUSE/guestmount GRUB QCOW2 builder (no loop devices)
│   ├── post-install.sh                # Services, initramfs, users, flatpak inside chroot
│   └── output/                        # Generated images and QEMU runner scripts
├── dagger_pipeline.py                 # Dagger orchestration (tarball + SquashFS + optional QCOW2)
└── README.md                          # This file
```

## Quick Start

### Prerequisites

Install Dagger and make sure you have a working Docker/Podman environment:

```bash
curl -fsSL https://dl.dagger.io/dagger/install.sh | bash
```

### Build COSMIC Desktop

```bash
cd /path/to/RegicideOSArch
dagger run python build-system/dagger_pipeline.py
```

This produces `regicide-arch.img`, a SquashFS live image in the current directory.

### Build an Unencrypted QCOW2 Disk Image

```bash
dagger run python build-system/dagger_pipeline.py --qcow2
```

This exports `build-system/arch/output/regicide-arch.tar.xz` and runs the guestfish
builder to produce `build-system/arch/output/regicide-arch.qcow2`. The generated
`build-system/arch/output/run-qemu.sh` script boots the result.

### Build an Encrypted QCOW2 Disk Image

```bash
dagger run python build-system/dagger_pipeline.py --encrypt
```

You will be prompted twice for a LUKS passphrase. The pipeline exports the tarball to
`build-system/arch/output/regicide-arch.tar.xz` and runs the loop-device GRUB builder
(`build-qemu-image.sh`) to produce `build-system/arch/output/regicide-arch.qcow2`.

### Build Only the QCOW2 from an Existing Tarball

If you already have a `regicide-arch.tar.xz`:

```bash
sudo ./build-system/arch/build-qemu-image.sh --encrypt --passphrase-file /run/luks-passphrase \
  build-system/arch/output/regicide-arch.tar.xz build-system/arch/output/regicide-arch.qcow2 30G
```

## Dagger Pipeline

The pipeline is a Python script using the Dagger SDK. It:

1. Starts from the official `archlinux:base-devel` image.
2. Initializes the pacman keyring and installs `archlinux-keyring` plus base/boot tooling.
3. Installs a base Arch system with `pacman`.
4. Installs the official COSMIC desktop group from the `extra` repository (`pacman -S cosmic`).
5. Runs `post-install.sh` inside the container to configure services, initramfs, users, and Flatpak.
6. Produces a compressed `regicide-arch.tar.xz` and a SquashFS `regicide-arch.img`.
7. Optionally exports the tarball to `build-system/arch/output/` and runs a host-side QCOW2 builder:
   - `--qcow2` uses `build-qemu-image-guestfish.sh` (no loop devices, systemd-boot).
   - `--encrypt` uses `build-qemu-image.sh` (loop devices, GRUB, LUKS2).

### Caching

Two Dagger cache volumes speed up repeated runs:

- `regicide-arch-pacman` — cached package downloads (`/var/cache/pacman/pkg`)
- `regicide-arch-alpine` — cached Alpine packages for the SquashFS stage

## Image Builders

Three QCOW2 builders are provided. The pipeline chooses automatically based on whether encryption is requested.

### `build-qemu-image.sh` (encrypted / full GRUB)

Creates a bootable UEFI QCOW2 image with:

- GPT partition table
- 512 MiB EFI system partition
- 12 GiB ROOTS Btrfs partition (optionally LUKS2-encrypted)
- 4 GiB OVERLAY Btrfs partition for writable overlay layers
- Remaining space as HOME Btrfs partition

It then:

- Extracts the tarball into ROOTS
- Creates overlay subvolumes on OVERLAY
- Generates `/etc/fstab` with overlay mounts
- Configures `mkinitcpio` with `sd-encrypt` and Btrfs hooks
- Installs GRUB for UEFI with LUKS modules when encryption is enabled
- Produces a `run-qemu.sh` helper script

### `build-qemu-image-guestfish.sh` (unencrypted / systemd-boot)

Pure libguestfs builder that requires no host loop devices and no chroot. It uses systemd-boot instead of GRUB and is the default for unencrypted `--qcow2` pipeline builds. Encrypted images are not supported; use `build-qemu-image.sh` for LUKS2.

### `build-qemu-image-guestmount.sh` (unencrypted / GRUB via FUSE)

Alternative libguestfs builder using guestmount/FUSE and GRUB. Also requires no loop devices and accepts `.tar.xz` input, but is not invoked by the pipeline by default.

## Why Arch?

The previous Gentoo/Catalyst pipeline relied on loop-device setup for Catalyst snapshots, which fails inside nested Dagger containers. Arch Linux provides:

- A clean `pacman`-based install model with no loop-device requirement
- Official COSMIC desktop packages in the `extra` repository
- Familiar mkinitcpio/initramfs tooling for LUKS/Btrfs boot
- Smaller, faster base image updates for CI builds

## Differences from RegicideOS (Gentoo)

| Component | RegicideOS | RegicideOSArch |
|-----------|------------|----------------|
| Base distro | Gentoo | Arch Linux |
| Stage builder | Catalyst | `pacman` |
| Initramfs | `dracut` | `mkinitcpio` |
| Kernel path | `/boot/vmlinuz` | `/boot/vmlinuz-linux` |
| Initramfs path | `/boot/initramfs.img` | `/boot/initramfs-linux.img` |
| COSMIC source | GURU/cosmic-overlay | Official `extra` group `cosmic` |
| Output tarball | `stage4-amd64-systemd-cosmic.tar.xz` | `build-system/arch/output/regicide-arch.tar.xz` |
| Output SquashFS | `regicide-cosmic.img` | `regicide-arch.img` |
| Output QCOW2 | `regicide-cosmic.qcow2` | `build-system/arch/output/regicide-arch.qcow2` |

## Notes

- Encrypted QCOW2 builds must run on the host (not inside Dagger) because they need loop devices and root privileges. Unencrypted builds use the guestfish builder and avoid loop devices.
- No GitHub Actions configuration is included; the pipeline is designed to run locally or from any cron-capable scheduler.
- Root password is set to `regicide` in the image; change it immediately on first boot.
