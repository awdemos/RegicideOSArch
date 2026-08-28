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
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

import dagger

import dagger_common


# Small built-in wordlists for memorable adjective-noun passphrases.
_ADJECTIVES = (
    "able", "apt", "avid", "bare", "bold", "brisk", "calm", "cool", "curt",
    "deft", "dire", "dual", "even", "fair", "fast", "firm", "fond", "free",
    "full", "gale", "glib", "good", "grim", "hardy", "huge", "hush", "iron",
    "jade", "jolly", "keen", "kind", "lax", "lean", "lush", "mere", "mild",
    "mute", "neat", "nice", "nimble", "open", "pale", "plucky", "prime",
    "quiet", "quick", "rapid", "rare", "raw", "real", "rich", "rough", "rugged",
    "safe", "sage", "sharp", "sleek", "slow", "smooth", "soft", "solid",
    "sound", "spry", "stark", "stout", "swift", "tame", "tart", "taut", "tidy",
    "trim", "true", "vast", "warm", "wild", "wiry", "wise", "witty", "zany",
)
_NOUNS = (
    "almond", "anchor", "arrow", "bison", "bronco", "canoe", "canyon",
    "cedar", "chisel", "cobalt", "comet", "copper", "crane", "crystal",
    "delta", "eagle", "elm", "falcon", "fjord", "flint", "fox", "gale",
    "gecko", "glacier", "grape", "harbor", "hawk", "heron", "ibis",
    "iron", "jackal", "jade", "koala", "lark", "lemon", "lotus", "lynx",
    "maple", "mesa", "mint", "moose", "newt", "oasis", "onion", "opal",
    "orca", "panda", "pearl", "pilot", "plum", "quartz", "rabbit", "raven",
    "reef", "ridge", "river", "robin", "rock", "sage", "salmon", "scorpion",
    "shark", "shore", "sparrow", "stone", "summit", "swan", "talon", "thorn",
    "tiger", "topaz", "valley", "violet", "wolf", "wren", "zest", "zinc",
)


def _generate_memorable_passphrase() -> str:
    """Return a memorable adjective-adjective-noun passphrase."""
    import secrets
    return "-".join([
        secrets.choice(_ADJECTIVES),
        secrets.choice(_ADJECTIVES),
        secrets.choice(_NOUNS),
    ])


def _generate_otp_style_passphrase(length: int = 32) -> str:
    """Return a long numeric string reminiscent of an OTP token."""
    import secrets
    return "".join(secrets.choice("0123456789") for _ in range(length))


def _generate_random_passphrase() -> str:
    """Return a high-entropy random passphrase."""
    import secrets
    return secrets.token_urlsafe(24)


def _check_container_runtime() -> None:
    """Fail fast if the local container runtime is rootless Podman or Docker.

    Dagger's engine image must create the 'dagger0' bridge, which rootless
    Podman cannot do. The Dagger SDK/CLI retry the connection for ~10 minutes
    before surfacing the real error, so an explicit up-front check saves time.
    If docker is unavailable or its info cannot be read, we skip the check:
    the user may be targeting a remote engine via _EXPERIMENTAL_DAGGER_RUNNER_HOST.
    """
    if os.environ.get("_EXPERIMENTAL_DAGGER_RUNNER_HOST"):
        return
    try:
        result = subprocess.run(
            ["docker", "info"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return
    if result.returncode != 0:
        return
    output = result.stdout.lower()
    # Podman rootless reports a standalone "rootless" line under Security Options.
    # Docker rootless reports "rootless: true".
    if re.search(r"^\s*rootless\s*$", output, re.MULTILINE) or "rootless: true" in output:
        print(
            "ERROR: Rootless Podman is not supported by the Dagger engine.\n"
            "The engine needs to create the 'dagger0' bridge, which requires root.\n"
            "Start the rootful Podman socket and re-run with:\n\n"
            "  sudo systemctl enable --now podman.socket\n"
            "  DOCKER_HOST=unix:///run/podman/podman.sock sudo -E \\\n"
            "      dagger run python build-system/dagger_pipeline.py --plain\n",
            file=sys.stderr,
        )
        sys.exit(1)


def _get_luks_passphrase(
    *,
    passphrase_file: Path | None = None,
    memorable: bool = False,
    otp_style: bool = False,
) -> str:
    """Return the LUKS passphrase from the most secure available source.

    Priority:
      1. Explicit --luks-passphrase-file contents (CI secret mode).
      2. REGICIDE_LUKS_PASSPHRASE environment variable (CI secret mode).
      3. Auto-generated passphrase printed once to stderr.

    The passphrase is printed exactly once on stderr so CI logs can capture it
    for the operator, but it is not emitted inside any Dagger container exec.
    """
    if passphrase_file is not None:
        raw = passphrase_file.read_text(encoding="utf-8")
        return raw.rstrip("\n")

    env_pass = os.environ.get("REGICIDE_LUKS_PASSPHRASE")
    if env_pass:
        return env_pass

    if memorable:
        passphrase = _generate_memorable_passphrase()
    elif otp_style:
        passphrase = _generate_otp_style_passphrase()
    else:
        passphrase = _generate_random_passphrase()

    print(
        "\n!!! ENCRYPTED IMAGE PASSPHRASE (copy before continuing) !!!\n"
        f"{passphrase}\n"
        "!!! This is the only time this passphrase is displayed. !!!\n",
        file=sys.stderr,
    )
    return passphrase


async def build_arch_cosmic(
    client: dagger.Client,
    enable_nvidia: bool = True,
    defer_flatpaks: bool = True,
) -> dagger.Container:
    """Build RegicideOSArch COSMIC rootfs in an Arch Linux container."""

    src = dagger_common.project_source_directory(client)
    base = dagger_common.arch_base_container(client)

    # Seed the pacman package cache into the container overlay, run the heavy
    # package install, then persist the cache.  We save again after post-install
    # so any additional packages downloaded there are also cached.
    seeded = dagger_common.seed_pacman_cache(base, client)
    with_packages = dagger_common.install_packages(seeded, "vm")
    with_packages = dagger_common.save_pacman_cache(with_packages, client)

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
    with_post = dagger_common.save_pacman_cache(with_post, client)

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
    compression_level: int = 15,
    processors: int = 4,
) -> dagger.File:
    """Create a SquashFS image from a stage4 tarball for live ISO use."""

    builder = (
        client.container()
        .from_("alpine:latest@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b")
    )

    # Seed/save the apk cache so the package install is cacheable.
    builder = dagger_common.seed_apk_cache(builder, client)
    builder = builder.with_exec(["apk", "add", "squashfs-tools", "tar", "xz"])
    builder = dagger_common.save_apk_cache(builder, client)

    builder = (
        builder
        .with_file("/tmp/regicide-arch.tar.xz", tarball)
        .with_exec(["mkdir", "-p", "/tmp/rootfs"])
        .with_exec([
            "tar", "-C", "/tmp/rootfs", "-xpJf", "/tmp/regicide-arch.tar.xz",
        ])
        .with_exec([
            "mksquashfs", "/tmp/rootfs", "/tmp/regicide-arch.img",
            "-comp", "zstd", "-Xcompression-level", str(compression_level),
            "-processors", str(processors),
        ])
    )

    return builder.file("/tmp/regicide-arch.img")


async def build_live_iso(
    client: dagger.Client,
    tarball: dagger.File,
    squashfs: dagger.File,
) -> dagger.File:
    """Create a bootable live ISO (GRUB + dracut dmsquash-live).

    The ISO boots the image kernel with an initramfs that mounts the
    SquashFS as a read-only live root, so the desktop can be tried or
    used for installation without touching a disk.
    """
    # 1. Generate the live initramfs inside the extracted rootfs so it
    # matches the exact kernel and userland being shipped. dracut is not in
    # the Arch image by default, so install it (and squashfs-tools for the
    # live module's helpers) from the Arch mirrors.
    initrd_builder = (
        dagger_common.arch_base_container(client)
        .with_file("/tmp/regicide-arch.tar.xz", tarball)
        .with_exec(["sh", "-c", "tar -C / -xpJf /tmp/regicide-arch.tar.xz --exclude=proc --exclude=sys --exclude=dev --exclude=opt --exclude=.init --exclude=etc/hosts --exclude=etc/resolv.conf --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./opt --exclude=./.init --exclude=./etc/hosts --exclude=./etc/resolv.conf && rm /tmp/regicide-arch.tar.xz"])
    )

    # Seed/save the pacman cache so the dracut package install is cacheable.
    initrd_builder = dagger_common.seed_pacman_cache(initrd_builder, client)
    initrd_builder = initrd_builder.with_exec(["pacman", "-S", "--noconfirm", "--needed", "dracut", "squashfs-tools"])
    initrd_builder = dagger_common.save_pacman_cache(initrd_builder, client)

    initrd_builder = initrd_builder.with_exec([
        "sh", "-c",
        "set -e; mkdir -p /work; kver=$(ls /lib/modules | head -1); "
        "cp /boot/vmlinuz-linux /work/vmlinuz; "
        "dracut --force --no-hostonly --add 'dmsquash-live' /work/initramfs.img ${kver}",
    ], insecure_root_capabilities=True)

    # 2. Assemble the ISO tree and run grub-mkrescue.
    grub_cfg = """set timeout=5
set default=0
menuentry "RegicideOS Arch (live)" {
    linux /boot/vmlinuz root=live:CDLABEL=REGICIDEOS rd.live.image rd.live.dir=/live rd.live.squashimg=rootfs.img console=tty0 console=ttyS0,115200n8
    initrd /boot/initramfs.img
}
menuentry "RegicideOS Arch (live, verbose)" {
    linux /boot/vmlinuz root=live:CDLABEL=REGICIDEOS rd.live.image rd.live.dir=/live rd.live.squashimg=rootfs.img console=tty0 console=ttyS0,115200n8 rd.debug
    initrd /boot/initramfs.img
}
"""
    iso_builder = (
        client.container()
        .from_("alpine:latest@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b")
        .with_exec(["apk", "add", "xorriso", "grub-efi", "grub-bios", "mtools"])
        .with_exec(["mkdir", "-p", "/iso/boot/grub", "/iso/live"])
        .with_file("/iso/boot/vmlinuz", initrd_builder.file("/work/vmlinuz"))
        .with_file("/iso/boot/initramfs.img", initrd_builder.file("/work/initramfs.img"))
        .with_file("/iso/live/rootfs.img", squashfs)
        .with_new_file("/iso/boot/grub/grub.cfg", grub_cfg)
        # The squashfs exceeds ISO9660's 4GiB file limit; force iso-level 3
        # (multi-extent). -iso-level is only valid in mkisofs-emulation mode,
        # so the wrapper injects it only after "-as mkisofs" (plain
        # "xorriso -version" must keep working for grub-mkrescue's probe).
        .with_new_file("/usr/local/bin/xorriso", '#!/bin/sh\nif [ "$1" = "-as" ] && [ "$2" = "mkisofs" ]; then\n  shift 2\n  exec /usr/bin/xorriso -as mkisofs -iso-level 3 "$@"\nfi\nexec /usr/bin/xorriso "$@"\n')
        .with_exec(["chmod", "+x", "/usr/local/bin/xorriso"])
        .with_exec([
            "grub-mkrescue",
            "-V", "REGICIDEOS",
            "-o", "/regicide-arch-live.iso", "/iso",
        ])
    )

    return iso_builder.file("/regicide-arch-live.iso")


async def _dagger_keepalive(client: dagger.Client, interval: float = 30.0) -> None:
    """Send a tiny no-op query every `interval` seconds to keep the Dagger
    session alive while a long-running host subprocess runs."""
    while True:
        try:
            await asyncio.sleep(interval)
            await client.container().from_("alpine").with_exec(
                ["echo", "dagger-keepalive"]
            ).stdout()
        except asyncio.CancelledError:
            return


def _stop_dagger_engine() -> None:
    """Stop any running Dagger engine containers to free memory before a
    long-running host-side step (the encrypted image builder boots its own KVM VM)."""
    try:
        result = subprocess.run(
            ["docker", "ps", "-q", "-f", "name=^/dagger-engine-"],
            check=False,
            capture_output=True,
            text=True,
        )
        for engine_id in result.stdout.splitlines():
            if engine_id:
                subprocess.run(
                    ["docker", "stop", "-t", "30", engine_id],
                    check=False,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
    except FileNotFoundError:
        pass


def _secure_wipe(path: Path) -> None:
    """Best-effort overwrite of a file before unlinking it."""
    try:
        with open(path, "rb+") as f:
            size = f.seek(0, os.SEEK_END)
            f.seek(0)
            f.write(b"\x00" * size)
            f.flush()
            os.fsync(f.fileno())
    except OSError:
        pass
    try:
        path.unlink()
    except FileNotFoundError:
        pass


async def build_qcow2_locally(
    tarball_path: Path,
    output_path: Path,
    disk_size: str,
    encrypt: bool,
    passphrase_file: Path | None = None,
    memorable: bool = False,
    otp_style: bool = False,
    squashfs_path: Path | None = None,
    client: dagger.Client | None = None,
) -> None:
    """Build a bootable QCOW2 image from a stage4 tarball on the host.

    The encrypted image uses build-vm-image.sh, which boots a KVM appliance to
    avoid host loop devices. The plain image uses build-qemu-image-guestfish.sh,
    which requires no host loop devices or passwordless sudo beyond the sudo it
    invokes itself. Default disk size is 20G to fit the 8+GiB uncompressed
    COSMIC rootfs plus overlay and home partitions.
    """
    if encrypt:
        script = Path(__file__).parent / "arch" / "build-vm-image.sh"
    else:
        script = Path(__file__).parent / "arch" / "build-qemu-image-guestfish.sh"
    if not script.exists():
        raise FileNotFoundError(f"Image builder script not found: {script}")

    env = os.environ.copy()

    cmd: list[str] = [
        str(script),
    ]

    generated_passphrase_file: Path | None = None
    if encrypt:
        passphrase = _get_luks_passphrase(
            passphrase_file=passphrase_file,
            memorable=memorable,
            otp_style=otp_style,
        )
        # Stage the passphrase in /dev/shm with 0600 permissions and no trailing
        # newline so cryptsetup reads the exact human passphrase. Write it in
        # binary mode because cryptsetup --key-file consumes the file verbatim.
        fd, passphrase_tmp = tempfile.mkstemp(
            prefix="regicide-luks-", dir="/dev/shm"
        )
        os.fchmod(fd, 0o600)
        generated_passphrase_file = Path(passphrase_tmp)
        with os.fdopen(fd, "wb") as f:
            f.write(passphrase.encode("utf-8"))
        cmd += [
            "--encrypt",
            "--passphrase-file",
            str(generated_passphrase_file),
        ]
        if squashfs_path is not None:
            cmd += ["--squashfs", str(squashfs_path)]
        print(f"Building encrypted QCOW2 image: {output_path}")
        # Do not let the passphrase escape into the builder's environment.
        env.pop("REGICIDE_LUKS_PASSPHRASE", None)
    else:
        print(f"Building unencrypted QCOW2 image: {output_path}")

    cmd += [str(tarball_path), str(output_path), disk_size]

    try:
        # Run the host builder while optionally keeping the Dagger session alive
        # with periodic no-op queries. Long-running subprocesses that do not
        # touch the Dagger API can otherwise look idle and cause the engine to
        # close the session (and SIGKILL the child).
        if client is not None:
            ping = asyncio.create_task(_dagger_keepalive(client))
        else:
            ping = None
        proc = await asyncio.create_subprocess_exec(*cmd, env=env)
        try:
            await proc.wait()
        finally:
            if ping is not None:
                ping.cancel()
                try:
                    await ping
                except asyncio.CancelledError:
                    pass
            if proc.returncode != 0:
                raise subprocess.CalledProcessError(proc.returncode, cmd)
    finally:
        if generated_passphrase_file is not None:
            _secure_wipe(generated_passphrase_file)

    print(f"QCOW2 image complete: {output_path}")


CHUNK_SIZE = "2G"
_CHUNK_RETRIES = 3


async def _export_file_with_retry(file: dagger.File, dest: Path) -> None:
    """Export a single file, retrying transient Dagger transport errors."""
    for attempt in range(_CHUNK_RETRIES):
        try:
            await file.export(str(dest))
            return
        except dagger.TransportError as exc:
            if attempt == _CHUNK_RETRIES - 1:
                raise
            print(
                f"  Export failed for {dest.name} ({exc}); retrying "
                f"({attempt + 1}/{_CHUNK_RETRIES})...",
                file=sys.stderr,
            )
            await asyncio.sleep(2 ** attempt)


async def export_tarball_in_chunks(
    container: dagger.Container,
    container_tar_path: str,
    local_path: Path,
) -> Path:
    """Export a large tarball in chunks to avoid Dagger fsync deadlocks/timeouts.

    The tarball is split inside the container into fixed-size pieces, each piece
    is exported separately, and the pieces are reassembled on the host.  This
    avoids the single multi-GB `File.export()` call that triggers
    `Server error '502 Bad Gateway'` under Podman and BuildKit's fsutil
    export path.
    """
    local_path = local_path.resolve()
    local_path.parent.mkdir(parents=True, exist_ok=True)
    chunk_dir = "/tmp/regicide-tarball-chunks"
    stem = local_path.name

    split_container = container.with_exec(
        [
            "sh",
            "-c",
            f"set -e; rm -rf {chunk_dir}; mkdir -p {chunk_dir}; "
            f"split -b {CHUNK_SIZE} -a 4 -d "
            f"{shlex.quote(container_tar_path)} "
            f"{shlex.quote(f'{chunk_dir}/{stem}.chunk_')}",
        ]
    )

    chunk_names = sorted(await split_container.directory(chunk_dir).entries())
    if not chunk_names:
        raise RuntimeError(f"no tarball chunks produced in {chunk_dir}")

    chunk_files: list[Path] = []
    for name in chunk_names:
        local_chunk = local_path.parent / name
        await _export_file_with_retry(split_container.file(f"{chunk_dir}/{name}"), local_chunk)
        chunk_files.append(local_chunk)

    # Reassemble on the host in a streaming fashion.
    with local_path.open("wb") as out:
        for chunk in chunk_files:
            with chunk.open("rb") as src:
                while True:
                    data = src.read(8 * 1024 * 1024)
                    if not data:
                        break
                    out.write(data)

    # Clean up chunk files once the tarball is complete and verified.
    total_size = local_path.stat().st_size
    for chunk in chunk_files:
        chunk.unlink()

    print(f"Exported {len(chunk_files)} chunks ({total_size} bytes total) -> {local_path}")
    return local_path


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
        help="Also build an encrypted QCOW2 disk image; auto-generate a passphrase if no secret source is provided",
    )
    parser.add_argument(
        "--luks-passphrase-file",
        type=Path,
        default=None,
        help="Path to a file containing the LUKS passphrase (CI secret mode; no terminal prompt)",
    )
    parser.add_argument(
        "--memorable-passphrase",
        action="store_true",
        help="Generate a human-readable adjective-adjective-noun passphrase instead of a random token",
    )
    parser.add_argument(
        "--otp-style-passphrase",
        action="store_true",
        help="Generate a long numeric passphrase reminiscent of an OTP token",
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
        "--iso",
        action="store_true",
        help="Also build a bootable live ISO (GRUB + dracut dmsquash-live) from the artifacts",
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
    parser.add_argument(
        "--run-vm-test",
        action="store_true",
        help="Run the post-install VM smoke test after building the QCOW2 image",
    )
    parser.add_argument(
        "--squashfs-compression-level",
        type=int,
        default=15,
        help="zstd compression level for the SquashFS image (default: 15)",
    )
    parser.add_argument(
        "--squashfs-processors",
        type=int,
        default=4,
        help="Number of processors mksquashfs may use (default: 4)",
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

    project_root = Path(__file__).resolve().parent.parent
    out_dir = project_root / "build-system" / "arch" / "output"
    squashfs_path = out_dir / "regicide-arch.img"

    _check_container_runtime()

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

        if tarball_path is None:
            print("Exporting stage4 tarball (chunked)...")
            tarball_path = await export_tarball_in_chunks(
                build_container,
                "/var/tmp/regicide-arch.tar.xz",
                out_dir / "regicide-arch.tar.xz",
            )
            print(f"Output: {tarball_path}")

        if squashfs_input is not None:
            print(f"Using existing SquashFS image: {squashfs_input}")
            if squashfs_input.resolve() != squashfs_path.resolve():
                subprocess.run(
                    ["cp", "-f", str(squashfs_input), str(squashfs_path)],
                    check=True,
                )
            else:
                print("SquashFS input path matches output path; reusing in place.")
        else:
            print("Creating SquashFS image...")
            iso_image = await build_iso(
                client,
                tarball,
                compression_level=args.squashfs_compression_level,
                processors=args.squashfs_processors,
            )
            await iso_image.export(str(squashfs_path))
        print(f"Output: {squashfs_path}")

        if args.iso:
            print("Building bootable live ISO (--iso)...")
            squashfs_for_iso = client.host().file(str(squashfs_path))
            live_iso = await build_live_iso(client, tarball, squashfs_for_iso)
            await live_iso.export(str(out_dir / "regicide-arch.iso"))
            print(f"Output: {out_dir / 'regicide-arch.iso'}")

    # Exit the Dagger session before the long host-side builder step. The
    # encrypted image builder boots its own KVM appliance, which needs a lot of
    # memory; stopping the Dagger engine frees resources for that VM.
    if args.qcow2 or args.encrypt:
        print("Shutting down Dagger engine to free memory for the host image builder...")
        _stop_dagger_engine()
        qcow2_output = Path(args.qcow2_output).resolve()
        if args.encrypt and not args.qcow2_output.endswith("-enc.qcow2"):
            # Use a distinct encrypted output path so VM tests and artifacts
            # do not collide with unencrypted builds.
            qcow2_output = qcow2_output.with_suffix("")
            qcow2_output = Path(str(qcow2_output) + "-enc.qcow2")
        await build_qcow2_locally(
            tarball_path=tarball_path,
            output_path=qcow2_output,
            disk_size=args.qcow2_size,
            encrypt=args.encrypt,
            passphrase_file=args.luks_passphrase_file,
            memorable=args.memorable_passphrase,
            otp_style=args.otp_style_passphrase,
            squashfs_path=squashfs_path,
            client=None,
        )
        if args.run_vm_test:
            print("Running stage7 artifact verification...")
            subprocess.run(
                ["./build-system/arch/stage7-verify.sh"],
                check=True,
            )
            print("Running stage8 post-install VM test...")
            subprocess.run(
                ["./build-system/arch/stage8-vm-test.sh", str(qcow2_output)],
                check=True,
            )


if __name__ == "__main__":
    asyncio.run(main())
