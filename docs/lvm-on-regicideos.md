# LVM on RegicideOSArch

RegicideOSArch ships with the LVM2 user-space tools and thin-provisioning support pre-installed. Btrfs is the default volume manager for the ROOTS/OVERLAY/HOME layout, but LVM is available when you need features Btrfs does not provide out of the box.

## When to use LVM

1. **Mixed filesystems on one disk**  
   Btrfs subvolumes all live in a single Btrfs filesystem. If you want a dedicated ext4, XFS, or swap volume alongside Btrfs, put LVM underneath and format each logical volume with the filesystem of your choice.

2. **Per-volume LUKS granularity**  
   Btrfs cannot encrypt individual subvolumes. With LVM-on-LUKS (or LUKS-on-LVM) you can encrypt separate logical volumes independently and unlock them with different passphrases or keys.

3. **Thin provisioning and snapshots outside Btrfs**  
   LVM thin pools let you over-provision and snapshot block devices. This is useful when you want snapshot/clone semantics for non-Btrfs data, VM disk images, or containers.

## Quick recipes

All commands require root privileges (`sudo -i` or `su -`).

### Recipe 1: Mix Btrfs and ext4 on the HOME partition

This keeps the existing HOME Btrfs layout but carves out a small ext4 logical volume for a game library or another application that prefers ext4.

```bash
# The HOME partition is /dev/vda4 in the default VM layout.
# Replace /dev/vda4 with the actual HOME device on your system.
HOME_DEV=/dev/vda4

# 1. Wipe the existing HOME partition. BACK UP YOUR DATA FIRST.
wipefs -a "${HOME_DEV}"

# 2. Create a physical volume and a volume group.
pvcreate "${HOME_DEV}"
vgcreate regicide-home "${HOME_DEV}"

# 3. Create a thin pool and two thin volumes.
#    80% of the VG for a thin pool, 100G for Btrfs HOME, 50G for ext4 data.
lvcreate -l 80%VG -T regicide-home/tpool
lvcreate -V 100G -T regicide-home/tpool -n home-btrfs
lvcreate -V 50G  -T regicide-home/tpool -n data-ext4

# 4. Format.
mkfs.btrfs /dev/regicide-home/home-btrfs
mkfs.ext4  /dev/regicide-home/data-ext4

# 5. Update /etc/fstab so HOME mounts at boot.
#    Use the stable /dev/mapper path or the UUID.
mkdir -p /home
mount /dev/regicide-home/home-btrfs /home
btrfs subvolume create /home/data 2>/dev/null || true
```

### Recipe 2: Per-volume LUKS passphrases with LUKS-on-LVM

This creates two logical volumes inside one LUKS container, then encrypts a second logical volume separately.

```bash
# Use an unused partition or block device. Replace /dev/vdb with your device.
DATA_DEV=/dev/vdb

# 1. Encrypt the whole data disk.
cryptsetup luksFormat "${DATA_DEV}"
cryptsetup open "${DATA_DEV}" data-luks

# 2. Put LVM on top of the decrypted device.
pvcreate /dev/mapper/data-luks
vgcreate regicide-data /dev/mapper/data-luks

# 3. Create logical volumes.
lvcreate -L 100G -n secure regicide-data
lvcreate -L 50G  -n private regicide-data

# 4. Encrypt one logical volume independently.
cryptsetup luksFormat /dev/regicide-data/private
cryptsetup open /dev/regicide-data/private private-luks

# 5. Format.
mkfs.btrfs /dev/mapper/secure
mkfs.ext4  /dev/mapper/private-luks

# 6. Mount.
mkdir -p /mnt/secure /mnt/private
mount /dev/mapper/secure /mnt/secure
mount /dev/mapper/private-luks /mnt/private
```

To unlock both volumes at boot, add `/etc/crypttab` entries and corresponding `/etc/fstab` entries, then regenerate the initramfs:

```bash
mkinitcpio -P
```

### Recipe 3: Thin-provisioned LVM for VM or container images

Use a thin pool when you want many sparse volumes that share physical space.

```bash
# Use an empty partition or disk.
POOL_DEV=/dev/vdc

pvcreate "${POOL_DEV}"
vgcreate regicide-thin "${POOL_DEV}"

# Create a thin pool that uses 90% of the VG.
lvcreate -l 90%VG -T regicide-thin/vmpool

# Create thin volumes. The sum of virtual sizes can exceed physical space.
lvcreate -V 100G -T regicide-thin/vmpool -n vm-fedora
lvcreate -V 100G -T regicide-thin/vmpool -n vm-debian
lvcreate -V 50G  -T regicide-thin/vmpool -n container-store

# Use them as raw disk images.
qemu-img convert -O raw /path/to/fedora.qcow2 /dev/regicide-thin/vm-fedora
mkfs.btrfs /dev/regicide-thin/container-store
```

Monitor real usage with:

```bash
lvs
vgs
```

## Important caveats

- **Do not** layer LVM between Btrfs and the ROOTS/OVERLAY partitions unless you know why you need it. The default layout keeps Btrfs directly on GPT partitions for simplicity.
- Resizing a Btrfs filesystem that sits on an LVM logical volume requires resizing both layers: first `lvextend`, then `btrfs filesystem resize max`.
- Keep backups. Repartitioning or reformatting erases data.

## Further reading

- `man lvm` and `man lvcreate`
- Arch Wiki: https://wiki.archlinux.org/title/LVM
- Arch Wiki: https://wiki.archlinux.org/title/Dm-crypt/Encrypting_a_non-root_file_system
