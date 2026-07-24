#!/usr/bin/env python3
"""RegicideOSArch WSL Build Pipeline.

Produces a gzip-compressed rootfs tarball suitable for `wsl --import`.

Usage:
  DAGGER_PROGRESS=plain dagger run python build-system/dagger_pipeline_wsl.py --plain
"""

import argparse
import asyncio
import os
import sys
from pathlib import Path

import dagger

import dagger_common


async def build_wsl_rootfs(
    client: dagger.Client,
    defer_flatpaks: bool = True,
) -> dagger.Container:
    """Build the RegicideOSArch WSL rootfs in an Arch Linux container."""

    src = dagger_common.project_source_directory(client)
    base = dagger_common.arch_base_container(client)
    with_packages = dagger_common.install_packages(base, "wsl")

    flatpaks_flag = "1" if defer_flatpaks else "0"
    with_post = dagger_common.run_post_install(
        with_packages,
        src,
        "post-install-wsl.sh",
        {
            "REGICIDE_ENABLE_NVIDIA": "0",
            "REGICIDE_DEFER_FLATPAKS": flatpaks_flag,
        },
    )

    return dagger_common.create_rootfs_tarball(
        with_post,
        "regicide-arch-wsl.tar.gz",
        compression="gzip",
    )


async def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build RegicideOSArch WSL rootfs tarball."
    )
    parser.add_argument(
        "--plain",
        action="store_true",
        help="Use plain Dagger progress output (useful for logs and CI)",
    )
    parser.add_argument(
        "--no-defer-flatpaks",
        dest="defer_flatpaks",
        action="store_false",
        default=True,
        help="Install all Flatpak apps during image build instead of on first boot",
    )
    parser.add_argument(
        "--output",
        default="build-system/arch/output/regicide-arch-wsl.tar.gz",
        help="Output path for the WSL rootfs tarball",
    )
    args = parser.parse_args()

    if args.plain:
        os.environ["DAGGER_PROGRESS"] = "plain"

    project_root = Path(__file__).resolve().parent.parent
    out_dir = project_root / "build-system" / "arch" / "output"
    out_dir.mkdir(parents=True, exist_ok=True)
    output_path = out_dir / Path(args.output).name

    config = dagger.Config(log_output=sys.stdout)
    async with dagger.Connection(config) as client:
        print("Building RegicideOSArch WSL rootfs...")
        container = await build_wsl_rootfs(client, defer_flatpaks=args.defer_flatpaks)
        tarball = container.file("/var/tmp/regicide-arch-wsl.tar.gz")

        print(f"Exporting WSL rootfs tarball to {output_path}...")
        await tarball.export(str(output_path))
        print(f"Output: {output_path}")


if __name__ == "__main__":
    asyncio.run(main())
