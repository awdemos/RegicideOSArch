#!/usr/bin/env python3
"""RegicideOSArch ARM64 Build Pipeline - Dagger orchestration for Arch Linux ARM builds.

Produces a bootable ARM64 rootfs, SquashFS live image, and QCOW2 VM image.
"""

import argparse
import asyncio
import os
import subprocess
import sys
from pathlib import Path

import dagger


def _cpu_count() -> int:
    """Return the number of host CPUs to expose to the build container."""
    return os.cpu_count() or 4


def _load_package_list(name: str) -> list[str]:
    """Read a newline-separated package list, skipping blanks and comments."""
    path = Path(__file__).parent / "packages" / f"{name}.txt"
    with path.open("r", encoding="utf-8") as f:
        return [line.strip() for line in f if line.strip() and not line.startswith("#")]


async def build_arch_cosmic_arm64(
    client: dagger.Client,
    defer_flatpaks: bool = True,
) -> dagger.Container:
    """Build RegicideOSArch COSMIC rootfs in an Arch Linux ARM container."""

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
            "*.vdi",
            "*.raw",
            "*.log",
            ".serena/",
            ".env",
            ".env.*",
        ],
    )

    jobs = _cpu_count()
    rootfs_dir = "/var/tmp/regicide-root"

    pacman_cache = client.cache_volume("regicide-arch-arm64-pacman")

    # Pinned Arch Linux ARM base image. The menci/archlinuxarm image is a
    # public AArch64 rootfs with working pacman/keyring configuration.
    base = (
        client.container()
        .from_("menci/archlinuxarm@sha256:4ce4f12cae8461f6293b7a3bd66da75f65c0a2786337aef847413cb707c3de48")
        .with_env_variable("MAKEFLAGS", f"-j{jobs}")
        .with_mounted_cache("/var/cache/pacman/pkg", pacman_cache)
    )

    # Arch Linux ARM's pacman uses sandboxing that fails inside Dagger's
    # container environment. Disable it before any sync/install operations.
    with_keyring = (
        base.with_exec([
            "bash", "-c",
            "sed -i '/^\\[options\\]/a DisableSandbox' /etc/pacman.conf; "
            "sed -i 's/^DownloadUser/#DownloadUser/' /etc/pacman.conf; "
            "pacman-key --init; "
            "pacman-key --populate archlinux; "
            "pacman -Sy --noconfirm archlinux-keyring || true",
        ])
        .with_exec([
            "bash", "-c",
            "pacman -S --noconfirm reflector || true; "
            "reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist || true; "
            "sed -i 's/^#DisableDownloadTimeout/DisableDownloadTimeout/' /etc/pacman.conf || true; "
            "grep -q '^DisableDownloadTimeout' /etc/pacman.conf || echo 'DisableDownloadTimeout' >> /etc/pacman.conf; "
            "cat >> /etc/pacman.conf <<'EOF'\n"
            "NoExtract = usr/share/doc/*\n"
            "NoExtract = usr/share/man/*\n"
            "NoExtract = usr/share/info/*\n"
            "NoExtract = usr/share/help/*\n"
            "NoExtract = usr/share/gtk-doc/html/*\n"
            "EOF",
        ])
    )

    flatpaks_flag = "1" if defer_flatpaks else "0"

    vm_packages = _load_package_list("vm-arm64")
    with_rootfs = with_keyring.with_exec(
        ["pacman", "-S", "--needed", "--noconfirm", "--disable-download-timeout"] + vm_packages
    )

    with_post = (
        with_rootfs
        .with_directory("/src", src)
        .with_exec(["cp", "-r", "/src/build-system/arch", "/tmp/regicide-arch-build"])
        .with_exec(
            [
                "bash", "-c",
                "REGICIDE_ENABLE_NVIDIA=1 "
                f"REGICIDE_DEFER_FLATPAKS={flatpaks_flag} "
                "SRC_DIR=/src bash /tmp/regicide-arch-build/post-install.sh",
            ]
        )
    )

    return with_post.with_exec(
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


async def build_qcow2_locally(
    tarball_path: Path,
    output_path: Path,
    disk_size: str,
) -> None:
    """Build a bootable ARM64 QCOW2 image from a stage4 tarball on the host."""

    script = Path(__file__).parent / "arch" / "build-qemu-image-arm64.sh"
    if not script.exists():
        raise FileNotFoundError(f"Image builder script not found: {script}")

    print(f"Building ARM64 QCOW2 image: {output_path}")
    subprocess.run(
        [str(script), str(tarball_path), str(output_path), disk_size],
        check=True,
    )
    print(f"QCOW2 image complete: {output_path}")


async def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build RegicideOSArch ARM64 COSMIC rootfs, SquashFS, and optional QCOW2."
    )
    parser.add_argument(
        "--plain",
        action="store_true",
        help="Use plain Dagger progress output (useful for logs and CI)",
    )
    parser.add_argument(
        "--qcow2",
        action="store_true",
        help="Also build an unencrypted ARM64 QCOW2 disk image",
    )
    parser.add_argument(
        "--qcow2-size",
        default="20G",
        help="Disk size for the optional QCOW2 image (default: 20G)",
    )
    parser.add_argument(
        "--qcow2-output",
        default="build-system/arch/output/regicide-arch-arm64.qcow2",
        help="Output path for the optional QCOW2 image",
    )
    parser.add_argument(
        "--no-defer-flatpaks",
        dest="defer_flatpaks",
        action="store_false",
        default=True,
        help="Install all Flatpak apps during the image build instead of on first boot",
    )
    args = parser.parse_args()

    if args.plain:
        os.environ["DAGGER_PROGRESS"] = "plain"

    config = dagger.Config(log_output=sys.stdout)
    async with dagger.Connection(config) as client:
        print("Building RegicideOSArch ARM64 COSMIC rootfs...")
        build_container = await build_arch_cosmic_arm64(
            client,
            defer_flatpaks=args.defer_flatpaks,
        )
        tarball = build_container.file("/var/tmp/regicide-arch.tar.xz")

        out_dir = Path("build-system/arch/output")

        print("Exporting stage4 tarball...")
        await tarball.export(str(out_dir / "regicide-arch-arm64.tar.xz"))
        print("Output: build-system/arch/output/regicide-arch-arm64.tar.xz")
        tarball_path = out_dir / "regicide-arch-arm64.tar.xz"

        print("Creating SquashFS image...")
        iso_image = await build_iso(client, tarball)
        squashfs_path = out_dir / "regicide-arch-arm64.img"
        await iso_image.export(str(squashfs_path))
        print(f"Output: {squashfs_path}")

        if args.qcow2:
            await build_qcow2_locally(
                tarball_path=tarball_path,
                output_path=Path(args.qcow2_output).resolve(),
                disk_size=args.qcow2_size,
            )


if __name__ == "__main__":
    asyncio.run(main())
