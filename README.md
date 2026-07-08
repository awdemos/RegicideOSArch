<div align="center">

# 🖥️ RegicideOSArch

### Arch Linux spin of RegicideOS · COSMIC Desktop · AI-Native experiments

> *Converge and conquer — on Arch.*

> ⚠️ **Development Status**: The Dagger build pipeline produces a bootable Arch-based rootfs, SquashFS live image, and QCOW2 VM image. COSMIC boots to a greeter, the `regicide` user can log in, and core apps (podman, distrobox, Rio, NVIDIA open drivers) are pre-installed. This is a side project of the main [RegicideOS](https://github.com/awdemos/RegicideOS) effort and is not the primary distribution.

[![Arch Linux](https://img.shields.io/badge/Arch%20Linux-1793D1?style=for-the-badge&logo=arch-linux&logoColor=white)](https://archlinux.org/)
[![Rust](https://img.shields.io/badge/Rust-000000?style=for-the-badge&logo=rust&logoColor=white)](https://www.rust-lang.org/)
[![Linux](https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black)](https://kernel.org/)
[![Btrfs](https://img.shields.io/badge/Btrfs-8db600?style=for-the-badge&logo=linux&logoColor=white)](https://btrfs.wiki.kernel.org/)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg?style=for-the-badge)](https://www.gnu.org/licenses/gpl-3.0)

</div>

---

## 🎯 What is RegicideOSArch?

**RegicideOSArch** is an Arch Linux-based experimental variant of [RegicideOS](https://github.com/awdemos/RegicideOS). It shares the same design goals — immutable Btrfs root, COSMIC desktop, container-first tooling, and AI-native system integration — but uses Arch Linux and `pacman` instead of Gentoo/Portage. The primary reason is that Arch provides official COSMIC packages in the `extra` repository and a clean `pacman`-based install model, making the build pipeline simpler and faster inside nested containers.

**This is a side project.** The main RegicideOS distribution remains the Gentoo-based effort in the [RegicideOS](https://github.com/awdemos/RegicideOS) repository.

---

## 🏗️ Architecture

> **Target note**: The current package set is optimized for the bootable QCOW2 VM image. A future ISO/bare-metal profile will diverge where needed. You can make this ISO-friendly by removing the following packages from the default install: `qemu-guest-agent`, `spice-vdagentd`, and the full `linux-firmware` bundle (replace it with targeted `linux-firmware-*` split packages such as `linux-firmware-iwlwifi`, `linux-firmware-rtw88`, `amd-ucode`, and `intel-ucode`).

| Component | Technology | Purpose | Status |
|-----------|------------|---------|--------|
| Base distro | Arch Linux | Rolling binary distribution | ✅ Working |
| Init System | systemd | Service management | ✅ Working |
| Filesystem | Btrfs (read-only root + overlays) | Immutable system image with writable layers | ✅ Working |
| Initramfs | mkinitcpio | Btrfs, LUKS, systemd hooks | ✅ Working |
| Bootloader | systemd-boot (unencrypted) / GRUB (encrypted) | UEFI boot | ✅ Working |
| Desktop | COSMIC (official `extra` group) | Wayland-native GPU desktop | ✅ Working |
| Container Runtime | podman + distrobox | Rootless containers and distro compatibility | ✅ Working |
| GPU | NVIDIA open-source driver (`nvidia-open-dkms`) | Proprietary-free NVIDIA stack; optional via `--no-nvidia` | ✅ Optional |
| Terminal | Rio (Flatpak) | GPU-accelerated terminal | ✅ Working |
| Packages | `build-system/packages/*.txt` | Shared package lists for VM/container variants | ✅ Added |

### Directory Layout

```
build-system/
├── arch/
│   ├── build-qemu-image.sh            # Encrypted LUKS + Btrfs + GRUB builder
│   ├── build-qemu-image-guestfish.sh  # Unencrypted systemd-boot builder (default)
│   ├── build-qemu-image-guestmount.sh # FUSE/guestmount GRUB builder
│   ├── post-install.sh                # Services, initramfs, users, flatpak
│   └── output/                        # Generated images and runner scripts
├── packages/                          # Shared package lists (VM, future ISO)
│   └── vm.txt                         # Default VM package set
├── dagger_pipeline.py                 # Dagger orchestration
└── README.md                          # Build-system reference
```

---

## 📥 Installation / Build

> **Note**: There is currently **no bootable ISO**. The build system produces a local SquashFS image and a bootable QCOW2 VM image. You can boot the QCOW2 directly in a VM.

### Requirements

- 64-bit x86 processor
- 12GB disk space minimum (20GB recommended)
- UEFI firmware (or OVMF for VMs)
- Internet connection
- Docker or Podman for Dagger

### Build from Source

#### 1. Install Dagger

```bash
curl -fsSL https://dl.dagger.io/dagger/install.sh | bash
```

#### 2. Build the unencrypted QCOW2 VM image

```bash
cd /path/to/RegicideOSArch
DAGGER_PROGRESS=plain dagger run python build-system/dagger_pipeline.py --qcow2
```

Outputs:
- `build-system/arch/output/regicide-arch.tar.xz` — compressed rootfs
- `build-system/arch/output/regicide-arch.img` — live SquashFS image
- `build-system/arch/output/regicide-arch.qcow2` — bootable VM disk

#### 3. Boot the image

```bash
sudo ./build-system/arch/output/run-qemu.sh
```

Or manually:

```bash
cp /usr/share/OVMF/OVMF_VARS.fd /tmp/ovmf-vars.fd
qemu-system-x86_64 \
    -enable-kvm -m 8G -smp 4 -cpu host -machine type=q35,accel=kvm \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=/tmp/ovmf-vars.fd \
    -drive file=build-system/arch/output/regicide-arch.qcow2,format=qcow2,if=virtio \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    -device virtio-net-pci,netdev=net0 \
    -vga qxl -vnc localhost:1 \
    -serial file:/tmp/regicide-serial.log \
    -monitor unix:/tmp/regicide-monitor.sock,server,nowait \
    -daemonize
```

Connect via noVNC:

```bash
python -m websockify --web /usr/share/novnc 6081 localhost:5901
```

Then open `http://localhost:6081/vnc.html?host=localhost&port=6081&autoconnect=true`.

> **Default credentials**: `regicide` / `regicide`. Root password is also `regicide`; change it immediately on first boot.

#### 4. Build options

| Flag | Purpose |
|------|---------|
| `--no-nvidia` | Skip the NVIDIA open-source driver stack (useful for CPU-only VMs or ISO prep). |
| `--no-defer-flatpaks` | Install all Flatpak apps during the image build instead of on first boot. |
| `--qcow2-size SIZE` | Set the output disk size, e.g. `30G` (default: `20G`). |
| `--qcow2-output PATH` | Set a custom output path for the QCOW2 image. |

Examples:

```bash
# Slim CPU-only VM image with no NVIDIA drivers and all Flatpaks pre-installed
DAGGER_PROGRESS=plain dagger run python build-system/dagger_pipeline.py --qcow2 --no-nvidia --no-defer-flatpaks

# Encrypted build (uses GRUB + LUKS2; prompts for a passphrase)
DAGGER_PROGRESS=plain dagger run python build-system/dagger_pipeline.py --encrypt
```

#### 5. Image builder environment variables

The QCOW2 builders read optional environment variables to size partitions. Defaults preserve the original layout.

| Variable | Default | Notes |
|----------|---------|-------|
| `REGICIDE_DISK_SIZE` | `20G` | Total raw disk size before QCOW2 conversion. |
| `REGICIDE_EFI_SIZE` | `512M` | EFI system partition. |
| `REGICIDE_ROOTS_SIZE` | `14G` (`12G` for encrypted builds) | Btrfs root partition. Increase if pre-installing many packages. |
| `REGICIDE_OVERLAY_SIZE` | `4G` | Overlay upperdir partition for writable `/etc`, `/var`, `/usr`. |

Example:

```bash
REGICIDE_ROOTS_SIZE=20G REGICIDE_OVERLAY_SIZE=8G \
  DAGGER_PROGRESS=plain dagger run python build-system/dagger_pipeline.py --qcow2
```

---

## 🤖 AI-Agent Build Procedure

Deterministic steps an AI agent can follow. All paths assume the repo was cloned into the current working directory.

### A. Build the QCOW2 image

1. Run the Dagger pipeline.

   ```bash
   cd "$(pwd)"
   DAGGER_PROGRESS=plain dagger run python build-system/dagger_pipeline.py --qcow2
   ```

2. Verify the tarball exists.

   ```bash
   test -f "$(pwd)/build-system/arch/output/regicide-arch.tar.xz"
   ```

3. Verify the SquashFS image exists and is non-empty.

   ```bash
   test -s "$(pwd)/build-system/arch/output/regicide-arch.img"
   ```

4. Verify the QCOW2 image exists.

   ```bash
   test -s "$(pwd)/build-system/arch/output/regicide-arch.qcow2"
   ```

5. Success criterion: all commands return exit code `0` and the QCOW2 file has a partition table.

   ```bash
   sudo parted -s "$(pwd)/build-system/arch/output/regicide-arch.qcow2" print > /dev/null 2>&1
   ```

### B. Boot the generated QCOW2

1. Ensure no other QEMU process is holding the image.

   ```bash
   pkill -9 -f 'qemu-system-x86_64.*regicide-arch' 2>/dev/null || true
   ```

2. Start the VM with the generated runner script.

   ```bash
   sudo ./build-system/arch/output/run-qemu.sh
   ```

3. Success criterion: the VM reaches the COSMIC greeter. Log in as `regicide` / `regicide` and run:

   ```bash
   systemctl status systemd-logind
   ```

   It should report `active (running)`.

---

## 🗺️ Roadmap

- [x] Bootable Arch-based QCOW2 VM image
- [x] COSMIC Desktop integration
- [x] NVIDIA open-source driver installation
- [x] podman + distrobox container tooling
- [x] Rio terminal Flatpak with Wayland launch fix
- [x] SSH and sudo enabled for default user
- [ ] Bootable ISO / bare-metal installer
- [ ] Rust replacements of core utilities
- [ ] AI-native system agents
- [ ] Merge learnings back into main RegicideOS (Gentoo)

---

## 🤝 Contributing

This is a side project; primary development focus remains on [RegicideOS](https://github.com/awdemos/RegicideOS). Contributions here are welcome for Arch-specific improvements, faster CI builds, and COSMIC packaging experiments.

**Found a bug?** File an issue in this repository with the command you ran, full logs, and your environment.

---

## 📜 License

RegicideOSArch is licensed under the **GNU General Public License v3.0**.

Built on the foundation of Arch Linux and the COSMIC Desktop ecosystem.

---

<div align="center">

**© 2026 Andrew White · RegicideOSArch (side project of RegicideOS)**

</div>
