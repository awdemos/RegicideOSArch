# Changelog

All notable changes to RegicideOSArch are documented in this file.

## [Unreleased]

### Added

- Shared package list at `build-system/packages/vm.txt` used by both the Dagger pipeline and the workspace Dockerfile.
- `--no-nvidia` build flag to skip the NVIDIA open-source driver stack for CPU-only VM images.
- `--no-defer-flatpaks` build flag to install all Flatpak apps during the image build instead of on first boot.
- `REGICIDE_DISK_SIZE`, `REGICIDE_EFI_SIZE`, `REGICIDE_ROOTS_SIZE`, and `REGICIDE_OVERLAY_SIZE` environment variables to customize QCOW2 partition layouts.
- First-boot systemd service `regicide-deferred-flatpaks.service` installs heavy Flatpak apps after the VM boots.

### Changed

- Default package set is now optimized for the bootable QCOW2 VM image:
  - Removed `base-devel`, `efibootmgr`, and `lvm2-monitor` from the default install.
  - `podman` and `distrobox` are no longer reinstalled in post-install.
- NVIDIA drivers are now optional and enabled by default; use `--no-nvidia` for smaller builds.
- Heavy Flatpak apps are now deferred to first boot by default, significantly reducing image size and build time.
- `pacman.conf` now uses `NoExtract` to strip docs, man pages, info pages, and GTK docs from the rootfs.
- Dagger pipeline no longer runs `mkinitcpio` redundantly; `99-finalize.sh` is the single rootfs-time run.
- Guestfish image builder now seeds overlay upperdirs with a Python-generated skeleton tarball instead of relying on a shell inside the appliance.
- Workspace Dockerfile now uses `archlinux:base` instead of `archlinux:base-devel`.

### Documentation

- README updated with build option flags, partition sizing env vars, and guidance on making the package set ISO/bare-metal friendly.

## [Earlier releases]

See the [git history](https://github.com/awdemos/RegicideOSArch/commits/main) for changes prior to this changelog.
