#!/usr/bin/env python3
"""Shared helpers for RegicideOSArch Dagger pipelines."""

import os
from pathlib import Path

import dagger


# Cache-volume keys used by the seed/save helpers below.  Keeping the names
# stable lets multiple pipeline runs share downloaded packages.
PACMAN_CACHE_NAME = "regicide-arch-pacman"
APK_CACHE_NAME = "regicide-arch-alpine"


def cpu_count() -> int:
    """Return the number of host CPUs to expose to the build container."""
    return os.cpu_count() or 4


def load_package_list(name: str) -> list[str]:
    """Read a newline-separated package list, skipping blanks and comments."""
    path = Path(__file__).parent / "packages" / f"{name}.txt"
    with path.open("r", encoding="utf-8") as f:
        return [line.strip() for line in f if line.strip() and not line.startswith("#")]


def project_source_directory(client: dagger.Client) -> dagger.Directory:
    """Return the project source directory with build artifacts excluded."""
    # Resolve relative to this file so the pipeline works regardless of CWD.
    project_root = Path(__file__).resolve().parent.parent
    return client.host().directory(
        str(project_root),
        exclude=[
            ".git/",
            "build-system/arch/output/",
            "target/",
            "*.img",
            "*.tar.xz",
            "*.tar.gz",
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


def _seed_cache(
    container: dagger.Container,
    client: dagger.Client,
    cache_name: str,
    mount_path: str,
    target_path: str,
) -> dagger.Container:
    """Copy cached files from a cache volume into the container overlay.

    Dagger >=0.21 does not cache execs that have a cache mount attached.  By
    seeding the target directory from a cache volume and then detaching it, the
    heavy package-manager operations become content-cacheable while still
    reusing previously downloaded artifacts.
    """
    cache = client.cache_volume(cache_name)
    return (
        container
        .with_mounted_cache(mount_path, cache)
        .with_exec(["mkdir", "-p", target_path, mount_path])
        .with_exec(
            [
                "sh",
                "-c",
                f"cp -au {mount_path}/. {target_path}/ 2>/dev/null || true",
            ]
        )
        .without_mount(mount_path)
    )


def _save_cache(
    container: dagger.Container,
    client: dagger.Client,
    cache_name: str,
    mount_path: str,
    source_path: str,
) -> dagger.Container:
    """Persist files from the container overlay back to a cache volume."""
    cache = client.cache_volume(cache_name)
    return (
        container
        .with_mounted_cache(mount_path, cache)
        .with_exec(["mkdir", "-p", mount_path])
        .with_exec(
            [
                "sh",
                "-c",
                f"cp -au {source_path}/. {mount_path}/ 2>/dev/null || true",
            ]
        )
        .without_mount(mount_path)
    )


def seed_pacman_cache(
    container: dagger.Container,
    client: dagger.Client,
    cache_name: str | None = None,
) -> dagger.Container:
    """Seed /var/cache/pacman/pkg from the persistent pacman cache volume."""
    return _seed_cache(
        container,
        client,
        cache_name or PACMAN_CACHE_NAME,
        "/cache/pacman/pkg",
        "/var/cache/pacman/pkg",
    )


def save_pacman_cache(
    container: dagger.Container,
    client: dagger.Client,
    cache_name: str | None = None,
) -> dagger.Container:
    """Persist /var/cache/pacman/pkg back to the pacman cache volume."""
    return _save_cache(
        container,
        client,
        cache_name or PACMAN_CACHE_NAME,
        "/cache/pacman/pkg",
        "/var/cache/pacman/pkg",
    )


def seed_apk_cache(
    container: dagger.Container,
    client: dagger.Client,
    cache_name: str | None = None,
) -> dagger.Container:
    """Seed /var/cache/apk from the persistent apk cache volume."""
    return _seed_cache(
        container,
        client,
        cache_name or APK_CACHE_NAME,
        "/cache/apk",
        "/var/cache/apk",
    )


def save_apk_cache(
    container: dagger.Container,
    client: dagger.Client,
    cache_name: str | None = None,
) -> dagger.Container:
    """Persist /var/cache/apk back to the apk cache volume."""
    return _save_cache(
        container,
        client,
        cache_name or APK_CACHE_NAME,
        "/cache/apk",
        "/var/cache/apk",
    )


def arch_base_container(client: dagger.Client) -> dagger.Container:
    """Return an Arch Linux base container with pacman keyring and mirrors ready.

    The pacman package cache is *not* mounted here.  Callers should seed the
    cache before heavy package operations and save it afterwards so Dagger can
    cache the expensive execs.
    """
    jobs = cpu_count()

    base = (
        client.container()
        .from_("archlinux:base-devel@sha256:9e9da3122b537ad94f22c8c6f89c1e3f253f3a1e22944364a061c75a041705da")
        .with_env_variable("MAKEFLAGS", f"-j{jobs}")
    )

    return (
        base.with_exec([
            "bash", "-c",
            "sed -i 's/^#DisableSandbox/DisableSandbox/' /etc/pacman.conf || true; "
            "grep -q '^DisableSandbox' /etc/pacman.conf || echo 'DisableSandbox' >> /etc/pacman.conf; "
            "sed -i 's/^DownloadUser/#DownloadUser/' /etc/pacman.conf || true",
        ])
        .with_exec(["pacman-key", "--init"])
        .with_exec(["pacman-key", "--populate", "archlinux"])
        .with_exec(["pacman", "-Sy", "--noconfirm", "archlinux-keyring"])
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


def install_packages(container: dagger.Container, package_profile: str) -> dagger.Container:
    """Install packages from a named package list with retry logic."""
    packages = load_package_list(package_profile)
    package_list = " ".join(packages)
    return container.with_exec(
        [
            "bash", "-c",
            "set -e; success=0; "
            "for i in 1 2 3 4 5; do "
            "  echo \"Attempt $i: installing packages...\"; "
            f"  if pacman -S --needed --noconfirm --disable-download-timeout {package_list}; then "
            "    success=1; break; "
            "  fi; "
            "  echo \"Attempt $i failed; waiting 15s before retry...\"; "
            "  sleep 15; "
            "done; "
            "if [[ $success -ne 1 ]]; then echo 'All package install attempts failed' >&2; exit 1; fi",
        ]
    )


def run_post_install(
    container: dagger.Container,
    src: dagger.Directory,
    script_name: str,
    env: dict[str, str],
) -> dagger.Container:
    """Run a post-install orchestrator script inside the container."""
    env_list = " ".join(f'{k}={v}' for k, v in env.items())
    return (
        container.with_directory("/src", src)
        .with_exec(["cp", "-r", "/src/build-system/arch", "/tmp/regicide-arch-build"])
        .with_exec(
            [
                "bash", "-c",
                f"{env_list} SRC_DIR=/src bash /tmp/regicide-arch-build/{script_name}",
            ]
        )
    )


def create_rootfs_tarball(
    container: dagger.Container,
    tarball_name: str,
    compression: str = "xz",
) -> dagger.Container:
    """Create a compressed rootfs tarball from the container rootfs."""
    rootfs_dir = "/var/tmp/regicide-root"
    tarball_path = f"/var/tmp/{tarball_name}"

    if compression == "gzip":
        tar_flags = "-czpf"
    elif compression == "xz":
        tar_flags = "-cpJf"
    else:
        raise ValueError(f"Unsupported compression: {compression}")

    return container.with_exec(
        [
            "bash", "-c",
            f"mkdir -p {rootfs_dir} && "
            f"tar {tar_flags} {tarball_path} "
            "--exclude=/dev --exclude=/proc --exclude=/sys --exclude=/run "
            "--exclude=/tmp --exclude=/var/tmp --exclude=/src --exclude=/work "
            "--exclude=/var/cache/pacman/pkg --exclude=/var/lib/pacman/sync "
            "--exclude=/regicide-arch.img --exclude=/regicide-arch.qcow2 "
            "--exclude=/regicide-arch.tar --exclude=/regicide-arch.tar.xz "
            "--exclude=/regicide-arch.tar.gz /",
        ]
    )
