#!/usr/bin/env python3
"""RegicideOSArch Build Pipeline - Dagger orchestration for Arch Linux builds.

Dagger is used here as an orchestration layer, not a replacement for the
Arch Linux-based build logic. The actual OS rootfs is built by
build-system/arch/post-install.sh inside an Arch container, and the bootable
QCOW2 image is produced by build-system/arch/build-qemu-image*.sh on the host.

Usage:
  DAGGER_PROGRESS=plain dagger run python build-system/dagger_pipeline.py --plain
  DAGGER_PROGRESS=plain dagger run python build-system/dagger_pipeline.py --plain --qcow2
  DAGGER_PROGRESS=plain dagger run python build-system/dagger_pipeline.py --plain --encrypt
"""

import argparse
import asyncio
import getpass
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import dagger


def _cpu_count() -> int:
    """Return the number of host CPUs to expose to the build container."""
    return os.cpu_count() or 4


async def build_arch_cosmic(
    client: dagger.Client,
    arch: str = "amd64",
    variant: str = "systemd",
) -> dagger.Container:
    """Build RegicideOSArch COSMIC rootfs in an Arch Linux container."""

    src = client.host().directory(
        ".",
        exclude=[
            ".git/",
            "build-system/arch/output/",
            "target/",
            "*.img",
            "*.tar.xz",
            "*.tar",
            "*.qcow2",
        ],
    )

    jobs = _cpu_count()
    rootfs_dir = "/var/tmp/regicide-root"

    # Cache pacman packages across Dagger runs to avoid re-downloading the world.
    pacman_cache = client.cache_volume("regicide-arch-pacman")

    # Pin the base image digest to avoid surprise re-downloads on tag drift.
    base = (
        client.container()
        .from_("archlinux:base-devel@sha256:9e9da3122b537ad94f22c8c6f89c1e3f253f3a1e22944364a061c75a041705da")
        .with_env_variable("MAKEFLAGS", f"-j{jobs}")
        .with_mounted_cache("/var/cache/pacman/pkg", pacman_cache)
    )

    with_keyring = (
        base.with_exec(["pacman-key", "--init"])
        .with_exec(["pacman-key", "--populate", "archlinux"])
        .with_exec(["pacman", "-Sy", "--noconfirm", "archlinux-keyring"])
        .with_exec([
            "bash", "-c",
            "pacman -S --noconfirm reflector || true; "
            "reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist || true; "
            "sed -i 's/^#DisableDownloadTimeout/DisableDownloadTimeout/' /etc/pacman.conf || true; "
            "grep -q '^DisableDownloadTimeout' /etc/pacman.conf || echo 'DisableDownloadTimeout' >> /etc/pacman.conf",
        ])
    )

    with_rootfs = with_keyring.with_exec(
        [
            "pacman", "-S", "--needed", "--noconfirm", "--disable-download-timeout",
            "base",
            "base-devel",
            "btrfs-progs",
            "cryptsetup",
            "dosfstools",
            "efibootmgr",
            "grub",
            "linux",
            "linux-firmware",
            "mkinitcpio",
            "networkmanager",
            "pipewire",
            "pipewire-alsa",
            "pipewire-jack",
            "pipewire-pulse",
            "wireplumber",
            "cosmic",
            "flatpak",
            "xdg-utils",
        ]
    )

    with_post = (
        with_rootfs
        .with_directory("/src", src)
        .with_exec(["cp", "/src/build-system/arch/post-install.sh", "/tmp/post-install.sh"])
        .with_exec(["bash", "/tmp/post-install.sh"])
    )

    with_initramfs = with_post.with_exec(
        [
            "bash", "-c",
            "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; "
            "mkinitcpio -P",
        ]
    )

    # Compress the intermediate tarball with xz. The extra CPU cost is
    # acceptable because it drastically reduces export time and the
    # downstream QCOW2 builders consume the .tar.xz format directly.
    return with_initramfs.with_exec(
        [
            "bash", "-c",
            f"mkdir -p {rootfs_dir} && "
            "tar -cpJf /var/tmp/regicide-arch.tar.xz "
            "--exclude=/dev --exclude=/proc --exclude=/sys --exclude=/run "
            "--exclude=/tmp --exclude=/var/tmp --exclude=/src --exclude=/work "
            "--exclude=/regicide-arch.img --exclude=/regicide-arch.qcow2 "
            "--exclude=/regicide-arch.tar --exclude=/regicide-arch.tar.xz /",
        ]
    )


async def build_iso(
    client: dagger.Client,
    tarball: dagger.File,
) -> dagger.File:
    """Create a SquashFS image from a stage4 tarball for live ISO use."""

    alpine_cache = client.cache_volume("regicide-arch-alpine")

    builder = (
        client.container()
        .from_("alpine:latest@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b")
        .with_mounted_cache("/var/cache/apk", alpine_cache)
        .with_exec(["apk", "add", "squashfs-tools", "tar", "xz"])
        .with_file("/tmp/regicide-arch.tar.xz", tarball)
        .with_exec(["mkdir", "-p", "/tmp/rootfs"])
        .with_exec([
            "tar", "-C", "/tmp/rootfs", "-xpJf", "/tmp/regicide-arch.tar.xz",
        ])
        .with_exec([
            "mksquashfs", "/tmp/rootfs", "/tmp/regicide-arch.img",
            "-comp", "zstd", "-Xcompression-level", "19",
        ])
    )

    return builder.file("/tmp/regicide-arch.img")


def _prompt_luks_passphrase() -> str:
    """Return the LUKS passphrase from the user, prompting twice."""
    while True:
        first = getpass.getpass("Enter LUKS passphrase for encrypted image: ")
        if not first:
            print("Passphrase cannot be empty.")
            continue
        second = getpass.getpass("Confirm LUKS passphrase: ")
        if first != second:
            print("Passphrases do not match. Try again.")
            continue
        return first


async def build_qcow2_locally(
    tarball_path: Path,
    output_path: Path,
    disk_size: str,
    encrypt: bool,
) -> None:
    """Build a bootable QCOW2 image from a stage4 tarball on the host.

    The encrypted image uses build-qemu-image.sh (loop-device + GRUB). The
    plain image uses build-qemu-image-guestfish.sh, which requires no host loop
    devices or passwordless sudo beyond the sudo it invokes itself.
    """
    script_name = "build-qemu-image.sh" if encrypt else "build-qemu-image-guestfish.sh"
    script = Path(__file__).parent / "arch" / script_name
    if not script.exists():
        raise FileNotFoundError(f"Image builder script not found: {script}")

    cmd: list[str] = [
        "sudo",
        str(script),
        str(tarball_path),
        str(output_path),
        disk_size,
    ]

    passphrase_file: Path | None = None
    if encrypt:
        passphrase = _prompt_luks_passphrase()
        fd, passphrase_tmp = tempfile.mkstemp(prefix="regicide-luks-", text=True)
        passphrase_file = Path(passphrase_tmp)
        with os.fdopen(fd, "w") as f:
            f.write(passphrase + "\n")
        passphrase_file.chmod(0o600)
        cmd[1:1] = ["--encrypt", "--passphrase-file", str(passphrase_file)]
        print(f"Building encrypted QCOW2 image: {output_path}")
    else:
        print(f"Building unencrypted QCOW2 image: {output_path}")

    try:
        subprocess.run(cmd, check=True)
    finally:
        if passphrase_file is not None:
            try:
                passphrase_file.unlink()
            except FileNotFoundError:
                pass

    print(f"QCOW2 image complete: {output_path}")


async def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build RegicideOSArch COSMIC rootfs, SquashFS, and optional QCOW2."
    )
    parser.add_argument(
        "--plain",
        action="store_true",
        help="Use plain Dagger progress output (useful for logs and CI)",
    )
    parser.add_argument(
        "--encrypt",
        action="store_true",
        help="Also build an encrypted QCOW2 disk image and prompt for a LUKS passphrase",
    )
    parser.add_argument(
        "--qcow2",
        action="store_true",
        help="Also build an unencrypted QCOW2 disk image (exports the tarball and runs build-qemu-image-guestfish.sh)",
    )
    parser.add_argument(
        "--qcow2-size",
        default="20G",
        help="Disk size for the optional QCOW2 image (default: 20G)",
    )
    parser.add_argument(
        "--qcow2-output",
        default="build-system/arch/output/regicide-arch.qcow2",
        help="Output path for the optional QCOW2 image (default: build-system/arch/output/regicide-arch.qcow2)",
    )
    parser.add_argument(
        "--from-tarball",
        type=Path,
        default=None,
        help="Reuse an existing stage4 tarball instead of rebuilding it in Dagger",
    )
    parser.add_argument(
        "--from-squashfs",
        type=Path,
        default=None,
        help="Reuse an existing SquashFS image instead of rebuilding it in Dagger",
    )
    args = parser.parse_args()

    if args.plain:
        os.environ["DAGGER_PROGRESS"] = "plain"

    tarball_path: Path | None = None
    squashfs_input: Path | None = None
    if args.from_tarball:
        tarball_path = args.from_tarball.resolve()
        if not tarball_path.is_file():
            print(f"Error: --from-tarball file not found: {tarball_path}", file=sys.stderr)
            sys.exit(1)
    if args.from_squashfs:
        squashfs_input = args.from_squashfs.resolve()
        if not squashfs_input.is_file():
            print(f"Error: --from-squashfs file not found: {squashfs_input}", file=sys.stderr)
            sys.exit(1)

    config = dagger.Config(log_output=sys.stdout)
    async with dagger.Connection(config) as client:
        if tarball_path is None:
            print("Building RegicideOSArch COSMIC rootfs...")
            build_container = await build_arch_cosmic(client)
            tarball = build_container.file("/var/tmp/regicide-arch.tar.xz")
        else:
            print(f"Using existing stage4 tarball: {tarball_path}")
            tarball = client.host().file(str(tarball_path))

        out_dir = Path("build-system/arch/output")

        if tarball_path is None:
            print("Exporting stage4 tarball...")
            await tarball.export(str(out_dir / "regicide-arch.tar.xz"))
            print("Output: build-system/arch/output/regicide-arch.tar.xz")
            tarball_path = out_dir / "regicide-arch.tar.xz"

        squashfs_path = out_dir / "regicide-arch.img"
        if squashfs_input is not None:
            print(f"Using existing SquashFS image: {squashfs_input}")
            subprocess.run(
                ["cp", "-f", str(squashfs_input), str(squashfs_path)],
                check=True,
            )
        else:
            print("Creating SquashFS image...")
            iso_image = await build_iso(client, tarball)
            await iso_image.export(str(squashfs_path))
        print(f"Output: {squashfs_path}")

        if args.qcow2 or args.encrypt:
            await build_qcow2_locally(
                tarball_path=tarball_path,
                output_path=Path(args.qcow2_output).resolve(),
                disk_size=args.qcow2_size,
                encrypt=args.encrypt,
            )


if __name__ == "__main__":
    asyncio.run(main())
