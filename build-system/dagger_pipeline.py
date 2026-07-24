#!/usr/bin/env python3
"""RegicideOSArch VM Build Pipeline - Dagger orchestration for Arch Linux builds.

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

import dagger_common


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


async def build_arch_cosmic(
    client: dagger.Client,
    enable_nvidia: bool = True,
    defer_flatpaks: bool = True,
) -> dagger.Container:
    """Build RegicideOSArch COSMIC rootfs in an Arch Linux container."""

    src = dagger_common.project_source_directory(client)
    base = dagger_common.arch_base_container(client)
    with_packages = dagger_common.install_packages(base, "vm")

    nvidia_flag = "1" if enable_nvidia else "0"
    flatpaks_flag = "1" if defer_flatpaks else "0"
    with_post = dagger_common.run_post_install(
        with_packages,
        src,
        "post-install.sh",
        {
            "REGICIDE_ENABLE_NVIDIA": nvidia_flag,
            "REGICIDE_DEFER_FLATPAKS": flatpaks_flag,
        },
    )

    # post-install.d/99-finalize.sh already runs mkinitcpio -P; the encrypted
    # image builder also runs it inside the chroot. Do not regenerate it here.

    # Compress the intermediate tarball with xz. The extra CPU cost is
    # acceptable because it drastically reduces export time and the
    # downstream QCOW2 builders consume the .tar.xz format directly.
    return dagger_common.create_rootfs_tarball(
        with_post,
        "regicide-arch.tar.xz",
        compression="xz",
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
        "--no-nvidia",
        action="store_true",
        help="Skip installing the NVIDIA open-source driver stack",
    )
    parser.add_argument(
        "--defer-flatpaks",
        action="store_true",
        default=True,
        help="Defer heavy Flatpak apps to a first-boot service (default: true)",
    )
    parser.add_argument(
        "--no-defer-flatpaks",
        dest="defer_flatpaks",
        action="store_false",
        help="Install all Flatpak apps during image build instead of on first boot",
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
            build_container = await build_arch_cosmic(
                client,
                enable_nvidia=not args.no_nvidia,
                defer_flatpaks=args.defer_flatpaks,
            )
            tarball = build_container.file("/var/tmp/regicide-arch.tar.xz")
        else:
            print(f"Using existing stage4 tarball: {tarball_path}")
            tarball = client.host().file(str(tarball_path))

        project_root = Path(__file__).resolve().parent.parent
        out_dir = project_root / "build-system" / "arch" / "output"

        if tarball_path is None:
            print("Exporting stage4 tarball...")
            tarball_path = out_dir / "regicide-arch.tar.xz"
            await tarball.export(str(tarball_path))
            print(f"Output: {tarball_path}")

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
