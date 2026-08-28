#!/usr/bin/env python3
"""CLI for pacman-based update operations with snapshot safety."""

import argparse
import glob
import os
import subprocess
import sys
from regicide_update import snapshots, common as rc


# Kernel packages installed by the RegicideOSArch image builders
# (build-system/packages/vm.txt uses linux; vm-arm64.txt uses linux-aarch64;
# linux-lts/linux-zen are common user-installed alternatives).
KERNEL_PACKAGES = ("linux", "linux-lts", "linux-zen", "linux-aarch64")


def run_pacman(*args: str) -> int:
    cmd = ["pacman"] + list(args)
    rc.info("Running: " + " ".join(cmd))
    return subprocess.call(cmd)


def _latest_kernel_version() -> str | None:
    modules_dir = "/lib/modules"
    try:
        versions = [d for d in os.listdir(modules_dir) if os.path.isdir(os.path.join(modules_dir, d))]
    except FileNotFoundError:
        return None
    if not versions:
        return None
    return sorted(versions)[-1]


def _kernel_changed_since_initramfs(kver: str) -> bool:
    modules_path = f"/lib/modules/{kver}"
    try:
        modules_mtime = os.stat(modules_path).st_mtime
    except FileNotFoundError:
        return False
    initramfs_files = glob.glob("/boot/initramfs*.img") + glob.glob("/boot/initrd*.img")
    if not initramfs_files:
        return True
    latest_initramfs = max(initramfs_files, key=os.path.getmtime)
    return modules_mtime > os.path.getmtime(latest_initramfs)


def _transaction_mentions_kernel(packages: list[str]) -> bool:
    return any(p.split("/")[-1] in KERNEL_PACKAGES for p in packages)


def maybe_refresh_bootloader(packages: list[str]) -> None:
    """Regenerate the initramfs when a kernel was installed or upgraded.

    RegicideOSArch images boot with systemd-boot entries pointing at stable
    kernel/initramfs paths, so only mkinitcpio needs to re-run; no
    bootloader-config refresh (e.g. grub-mkconfig) is required.
    """
    kver = _latest_kernel_version()
    if kver is None:
        return
    if not (_transaction_mentions_kernel(packages) or _kernel_changed_since_initramfs(kver)):
        return
    rc.info(f"Kernel {kver} changed; regenerating initramfs.")
    rc.execute("mkinitcpio", ["-P"])


def cmd_sync(_args: argparse.Namespace) -> None:
    sys.exit(run_pacman("-Sy"))


def cmd_search(args: argparse.Namespace) -> None:
    sys.exit(run_pacman("-Ss", args.query))


def _transaction(args: argparse.Namespace, tag_prefix: str, pacman_args: list[str], packages: list[str]) -> None:
    pre = snapshots.create_snapshot_set(f"pre_{tag_prefix}")
    rc.info(f"Pre-transaction snapshot: {pre}")
    code = run_pacman(*pacman_args)
    if code == 0:
        post = snapshots.create_snapshot_set(f"post_{tag_prefix}")
        rc.info(f"Post-transaction snapshot: {post}")
        snapshots.apply_retention()
        maybe_refresh_bootloader(packages)
    else:
        rc.warn(f"{tag_prefix.capitalize()} failed.")
        if not args.no_rollback:
            snapshots.set_revert(pre)
            rc.warn(f"Reboot to roll back to {pre}.")
    sys.exit(code)


def cmd_upgrade(args: argparse.Namespace) -> None:
    _transaction(args, "upgrade", ["-Su"], [])


def cmd_install(args: argparse.Namespace) -> None:
    _transaction(args, "install", ["-S", *args.packages], args.packages)


def cmd_remove(args: argparse.Namespace) -> None:
    _transaction(args, "remove", ["-Rns", *args.packages], args.packages)


def main() -> None:
    rc.require_root()
    parser = argparse.ArgumentParser(prog="regicide-update")
    sub = parser.add_subparsers(dest="action", required=True)

    sub.add_parser("sync", help="Sync package databases")

    search = sub.add_parser("search", help="Search packages")
    search.add_argument("query")

    upgrade = sub.add_parser("upgrade", help="Upgrade installed packages")
    upgrade.add_argument("--no-rollback", action="store_true")

    install = sub.add_parser("install", help="Install packages")
    install.add_argument("packages", nargs="+")
    install.add_argument("--no-rollback", action="store_true")

    remove = sub.add_parser("remove", help="Remove packages")
    remove.add_argument("packages", nargs="+")
    remove.add_argument("--no-rollback", action="store_true")

    args = parser.parse_args()
    match args.action:
        case "sync":
            cmd_sync(args)
        case "search":
            cmd_search(args)
        case "upgrade":
            cmd_upgrade(args)
        case "install":
            cmd_install(args)
        case "remove":
            cmd_remove(args)


if __name__ == "__main__":
    main()
