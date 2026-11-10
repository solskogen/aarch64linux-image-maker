#!/bin/bash
# Description: Script to create both RPi5 and Mainline AArch64 Arch Linux images efficiently.
#              Runs fully rootless (no root/sudo): chroot work happens in user namespaces
#              (pacstrap -N / arch-chroot -N) and the disk image is assembled from plain
#              directories, so no loop devices or mounts are needed.
# Usage: ./create_image.sh [-o|--output-dir <dir>] [--root-fs ext4|btrfs] {rpi|mainline}  (If no argument provided, builds both by default)
set -e
set -o pipefail

usage() {
    cat <<'EOF'
Usage: ./create_image.sh [-o|--output-dir <directory>] [--root-fs ext4|btrfs] [rpi|mainline]

Runs as a regular user (no root/sudo needed).
Give at most one target; if none is provided, both image types are built.
--root-fs defaults to ext4.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments
OUTPUT_DIR="$(pwd)"
TARGET_TYPE=""
ROOT_FS="ext4"

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -o|--output-dir)
            [[ $# -ge 2 ]] || { usage; exit 1; }
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --root-fs)
            [[ $# -ge 2 ]] || { usage; exit 1; }
            ROOT_FS="$2"
            shift 2
            ;;
        rpi|mainline)
            if [[ -n "$TARGET_TYPE" ]]; then
                echo "ERROR: Only one target can be given; omit the target to build both"
                usage
                exit 1
            fi
            TARGET_TYPE="$1"
            shift
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

if [[ "$ROOT_FS" != "ext4" && "$ROOT_FS" != "btrfs" ]]; then
    echo "ERROR: --root-fs must be 'ext4' or 'btrfs'"
    exit 1
fi

# Everything runs unprivileged inside user namespaces; real root would bypass the
# subuid/subgid mapping that file ownership in the image relies on.
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Do not run this script as root or with sudo; run it as a regular user"
    exit 1
fi

# Detect host architecture for cross-compilation support
HOST_ARCH=$(uname -m)
CROSS_BUILD=false
if [[ "$HOST_ARCH" != "aarch64" ]]; then
    CROSS_BUILD=true
    echo "Host architecture: $HOST_ARCH — will cross-build aarch64 images using QEMU"
fi

# Check for required dependencies (cannot be auto-installed without root)
declare -A REQUIRED_COMMAND_PACKAGES=(
    [pacstrap]=arch-install-scripts
    [arch-chroot]=arch-install-scripts
    [unshare]=util-linux
    [uuidgen]=util-linux
    [sfdisk]=util-linux
    [newuidmap]=shadow
    [newgidmap]=shadow
    [pacman-key]=pacman
    [gpgconf]=gnupg
    [wget]=wget
    [zstd]=zstd
    [jq]=jq
    [mkfs.vfat]=dosfstools
    [mcopy]=mtools
    [mkfs.ext4]=e2fsprogs
    [mkfs.btrfs]=btrfs-progs
)

# Add QEMU dependencies for cross-building
if $CROSS_BUILD; then
    REQUIRED_COMMAND_PACKAGES[qemu-aarch64-static]=qemu-user-static
fi

MISSING_PACKAGES=()
declare -A SEEN_PACKAGES=()
for cmd in "${!REQUIRED_COMMAND_PACKAGES[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        pkg="${REQUIRED_COMMAND_PACKAGES[$cmd]}"
        if [[ -z "${SEEN_PACKAGES[$pkg]:-}" ]]; then
            MISSING_PACKAGES+=("$pkg")
            SEEN_PACKAGES[$pkg]=1
        fi
    fi
done

# Also ensure binfmt package is installed for cross-building
if $CROSS_BUILD && ! pacman -Qi qemu-user-static-binfmt >/dev/null 2>&1; then
    if [[ -z "${SEEN_PACKAGES[qemu-user-static-binfmt]:-}" ]]; then
        MISSING_PACKAGES+=("qemu-user-static-binfmt")
        SEEN_PACKAGES[qemu-user-static-binfmt]=1
    fi
fi

if (( ${#MISSING_PACKAGES[@]} > 0 )); then
    echo "ERROR: Missing required packages: ${MISSING_PACKAGES[*]}"
    echo "Install them (as root) with: pacman -S --needed ${MISSING_PACKAGES[*]}"
    exit 1
fi

# Rootless mode needs subuid/subgid ranges and unprivileged user namespaces
for map_file in /etc/subuid /etc/subgid; do
    if ! grep -qE "^($(id -un)|$(id -u)):" "$map_file" 2>/dev/null; then
        echo "ERROR: No entry for $(id -un) in $map_file"
        echo "Add one (as root) with: usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $(id -un)"
        exit 1
    fi
done

# Run a command as (namespaced) root with the same uid/gid mapping that
# pacstrap -N and arch-chroot -N use, so file ownership stays consistent.
ns() {
    unshare --map-auto --map-root-user --setuid 0 --setgid 0 "$@"
}

if ! ns true 2>/dev/null; then
    echo "ERROR: Unable to create a user namespace with subuid/subgid mapping"
    echo "Check that unprivileged user namespaces are enabled and /etc/subuid, /etc/subgid are set up"
    exit 1
fi

# QEMU user-mode emulation for cross-building (registration itself needs root, once per boot)
if $CROSS_BUILD && [[ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
    echo "ERROR: QEMU aarch64 binfmt_misc registration not found"
    echo "Ask an administrator to run: systemctl restart systemd-binfmt"
    echo "(requires qemu-user-static-binfmt and binfmt_misc support in the kernel)"
    exit 1
fi

# Repository configuration (single source of truth for the custom aarch64 repo)
REPO_BASE_URL="https://arch-linux-repo.drzee.net/arch"
REPO_SIGNING_KEY="0CF25682E6BA0751"

# Configuration
IMG_SIZE="2500M"
BUILD_DATE=$(date +%Y.%m.%d)
PKG_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/aarch64linux-image-maker/pkg"

# Determine which images to build
if [[ "$TARGET_TYPE" == "rpi" ]]; then
    BUILDS=("rpi")
elif [[ "$TARGET_TYPE" == "mainline" ]]; then
    BUILDS=("mainline")
else
    BUILDS=("rpi" "mainline") # Build both by default
fi

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR" "$PKG_CACHE"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)

# Global variables for cleanup tracking
WORK=""
GNUPGHOME_DIR=""
CURRENT_TARGET_IMG=""
CURRENT_OUTPUT_FILE=""

# Cleanup function for exit/failure/interrupt
cleanup() {
    echo "Running cleanup function..."

    # Remove incomplete image/compressed output left behind by an interrupted run.
    if [ -n "$CURRENT_TARGET_IMG" ] && [ -f "$CURRENT_TARGET_IMG" ]; then
        echo "Removing incomplete image $CURRENT_TARGET_IMG..."
        rm -f "$CURRENT_TARGET_IMG"
    fi
    if [ -n "$CURRENT_OUTPUT_FILE" ] && [ -f "$CURRENT_OUTPUT_FILE" ]; then
        echo "Removing incomplete compressed output $CURRENT_OUTPUT_FILE..."
        rm -f "$CURRENT_OUTPUT_FILE"
    fi

    # Stop the private keyring's gpg-agent, then remove the work tree. Some files
    # are owned by subuids, so removal must happen inside the user namespace.
    if [ -n "$GNUPGHOME_DIR" ] && [ -d "$GNUPGHOME_DIR" ]; then
        ns gpgconf --homedir "$GNUPGHOME_DIR" --kill all 2>/dev/null || true
    fi
    if [ -n "$WORK" ] && [ -d "$WORK" ]; then
        ns rm -rf "$WORK" 2>/dev/null || true
    fi
}

# Set up cleanup trap (signals exit explicitly so the script doesn't resume after cleanup)
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

WORK=$(mktemp -d -p "$OUTPUT_DIR" .aarch64linux-build.XXXXXX)
GNUPGHOME_DIR="$WORK/gnupg"
BASE_ROOT="$WORK/base"
PACMAN_CONF="$WORK/pacman.conf"
BASE_IMG_SIZE_MB=${IMG_SIZE%M}

# Preflight disk space check: base tree + one tree/partition images/raw image per
# target must fit, with headroom for the compressed .zst output.
REQUIRED_MB=$(( BASE_IMG_SIZE_MB * 3 + BASE_IMG_SIZE_MB / 2 ))
AVAILABLE_MB=$(df --output=avail -BM "$OUTPUT_DIR" | tail -1 | tr -dc '0-9')
if [ -n "$AVAILABLE_MB" ] && [ "$AVAILABLE_MB" -lt "$REQUIRED_MB" ]; then
    echo "ERROR: Not enough space in $OUTPUT_DIR (need ~${REQUIRED_MB}M, have ${AVAILABLE_MB}M)"
    exit 1
fi

# Preflight: confirm before overwriting any pre-existing output image. Checked
# upfront (before any build work starts) so a "no" doesn't waste a full build.
for build_type in "${BUILDS[@]}"; do
    EXISTING_OUTPUT="$OUTPUT_DIR/archlinux-${build_type}-${BUILD_DATE}-aarch64.img.zst"
    if [ -e "$EXISTING_OUTPUT" ]; then
        CONFIRM_OVERWRITE=""
        read -r -p "Output file $EXISTING_OUTPUT already exists. Overwrite? [y/N] " CONFIRM_OVERWRITE || true
        case "$CONFIRM_OVERWRITE" in
            [yY]|[yY][eE][sS]) ;;
            *) echo "ERROR: Aborting: $EXISTING_OUTPUT already exists and overwrite was declined."; exit 1 ;;
        esac
    fi
done

# Create custom pacman.conf for aarch64 target packages. The keyring and package
# cache live in user-writable locations so no host files need to be modified.
cat > "$PACMAN_CONF" << CONFEOF
[options]
HoldPkg = pacman glibc
Architecture = aarch64
CheckSpace
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
ParallelDownloads = 5
GPGDir = $GNUPGHOME_DIR
CacheDir = $PKG_CACHE

[forge]
Server = $REPO_BASE_URL/\$repo/os/\$arch

[core]
Server = $REPO_BASE_URL/\$repo/os/\$arch

[extra]
Server = $REPO_BASE_URL/\$repo/os/\$arch
CONFEOF

# Import repository signing key into a private build keyring (needed for pacstrap)
echo "Importing repository signing key..."
wget --timeout=30 -qO "$WORK/public.key" "$REPO_BASE_URL/extra/os/aarch64/public.key" || { echo "ERROR: Failed to download repository signing key"; exit 1; }
mkdir -p "$GNUPGHOME_DIR"
chmod 700 "$GNUPGHOME_DIR"
ns pacman-key --config "$PACMAN_CONF" --gpgdir "$GNUPGHOME_DIR" --init || { echo "ERROR: Failed to initialize build keyring"; exit 1; }
ns pacman-key --config "$PACMAN_CONF" --gpgdir "$GNUPGHOME_DIR" --add "$WORK/public.key" || { echo "ERROR: Failed to import repository signing key"; exit 1; }
ns pacman-key --config "$PACMAN_CONF" --gpgdir "$GNUPGHOME_DIR" --lsign-key "$REPO_SIGNING_KEY" || { echo "ERROR: Failed to locally sign repository key"; exit 1; }
ns gpgconf --homedir "$GNUPGHOME_DIR" --kill all 2>/dev/null || true

# Function to install base system
install_base_system() {
    local ROOT_DIR=$1

    echo "Installing base system..."
    mkdir -p "$ROOT_DIR"
    # -K: give the image a fresh keyring instead of copying the host's (which would
    # leak the host's pacman master key into every image)
    if ! pacstrap -N -K -c -C "$PACMAN_CONF" "$ROOT_DIR" base vim btrfs-progs dosfstools e2fsprogs arch-install-scripts linux-firmware mkinitcpio; then
        echo "ERROR: pacstrap install failed"
        exit 1
    fi

    # Verify installation
    [ -f "$ROOT_DIR/etc/pacman.conf" ] || { echo "ERROR: Base system installation incomplete"; exit 1; }
}

# Function to configure base system
configure_base_system() {
    local ROOT_DIR=$1

    echo "Configuring base system..."

    # /etc/pacman.conf inside the image is provided by our own pacman package
    # (installed via pacstrap) and is left completely untouched.

    # Network configuration
    rm -f "$ROOT_DIR/etc/resolv.conf"
    ln -s /run/systemd/resolve/stub-resolv.conf "$ROOT_DIR/etc/resolv.conf"
    ln -sf ../../../../usr/lib/systemd/system/multi-user.target "$ROOT_DIR/etc/systemd/system/default.target"

    # System settings
    echo "aarch64linux" > "$ROOT_DIR/etc/hostname"
    # Empty root password (equivalent of `passwd -d root`, which would need chroot())
    sed -i 's/^root:[^:]*:/root::/' "$ROOT_DIR/etc/shadow"
    systemctl --root="$ROOT_DIR" enable systemd-networkd systemd-resolved > /dev/null

    # Network configuration
    mkdir -p "$ROOT_DIR/etc/systemd/network"
    cat > "$ROOT_DIR/etc/systemd/network/20-wired.network" << 'EOF'
[Match]
Name=e*
[Network]
DHCP=yes
EOF

    # Install repository public key
    cp "$WORK/public.key" "$ROOT_DIR/root/"
    arch-chroot -N "$ROOT_DIR" pacman-key --init
    arch-chroot -N "$ROOT_DIR" pacman-key --populate
    arch-chroot -N "$ROOT_DIR" pacman-key --add /root/public.key
    arch-chroot -N "$ROOT_DIR" pacman-key --lsign-key "$REPO_SIGNING_KEY"
    ns rm -f "$ROOT_DIR/root/public.key"

    # Resize helper plus instructions (the manual fallback depends on the root filesystem type)
    ns install -D -m 755 "$SCRIPT_DIR/expand-rootfs" "$ROOT_DIR/usr/local/bin/expand-rootfs"

    if [[ "$ROOT_FS" == "btrfs" ]]; then
        RESIZE_STEP=$(cat <<'STEPEOF'
2.  **Grow the filesystem.**
    Btrfs grows online while mounted, so nothing needs to be unmounted:

        btrfs filesystem resize max /
STEPEOF
)
    else
        RESIZE_STEP=$(cat <<'STEPEOF'
2.  **Grow the filesystem.**
    ext4 grows online while mounted. Give `resize2fs` the root partition:

        resize2fs /dev/mmcblk0p2
STEPEOF
)
    fi

    local README_TMP="$WORK/README_RESIZE.txt"
    {
        cat <<EOF
# Expanding the root filesystem after flashing

This image is only about 2.5 GB. After you write it to a larger SD card or SSD,
the rest of the disk stays unused until you grow the root partition and the
filesystem on it ($ROOT_FS). This is done by hand, on the running system, with
no reboot and nothing to unmount.

## Quick way

Log in as root (this image does not include sudo) and run:

    expand-rootfs

It finds your root partition, grows it to the end of the disk, grows the
filesystem to match, and prints 'df -h /' before and after. When it succeeds it
deletes itself, since it is only needed once.

## Manual way

The root partition is the last one on the disk, so it can grow into the free
space behind it. The examples assume an SD card (/dev/mmcblk0, root partition
number 2). Run 'lsblk' to find yours: SD/eMMC is usually mmcblk0p2, USB/SATA
sda2, NVMe nvme0n1p2.

1.  **Grow the partition.**
    'sfdisk' (from util-linux, already installed) can do this on a mounted disk:

        echo ', +' | sfdisk --no-reread -N 2 /dev/mmcblk0

    ', +' means "keep the start, grow to the end of the disk". sfdisk will say
    it could not re-read the partition table because the disk is in use; that
    is expected. Tell the kernel about the new size with:

        partx -u /dev/mmcblk0

EOF
        printf '%s\n\n' "$RESIZE_STEP"
        cat <<'EOF'
3.  **Verify.**
    'df -h /' should now show the full size of your disk.
EOF
    } > "$README_TMP"
    # / is mode 555, so install it as namespaced root
    ns install -m 644 "$README_TMP" "$ROOT_DIR/README_RESIZE.txt"
    rm -f "$README_TMP"

    # Optimize mkinitcpio configuration
    # These images are meant to run on varied hardware, so drop autodetect
    # (which trims hooks/modules to the build host) and microcode (CPU-specific).
    sed -i '/^HOOKS=/s/autodetect //' "$ROOT_DIR/etc/mkinitcpio.conf"
    sed -i '/^HOOKS=/s/microcode //' "$ROOT_DIR/etc/mkinitcpio.conf"

    # Create a non-empty vconsole.conf (the default keymap) to prevent mkinitcpio/systemd warnings
    echo "KEYMAP=us" > "$ROOT_DIR/etc/vconsole.conf"
}

# Function to configure fstab and bootloader for specific target type.
# The boot partition is staged as the /boot directory of the root tree.
configure_boot() {
    local TYPE=$1
    local ROOT_DIR=$2
    local ROOT_SPEC="PARTUUID=$ROOT_PARTUUID"
    local BOOT_SPEC="PARTUUID=$BOOT_PARTUUID"
    local ROOT_FSTAB_OPTS="rw,relatime"
    local ROOT_FSTAB_PASS=1
    if [[ "$ROOT_FS" == "btrfs" ]]; then
        ROOT_FSTAB_PASS=0
    fi

    # Generate fstab (genfstab needs real mounts, so write it directly)
    cat > "$ROOT_DIR/etc/fstab" << EOF
# Static information about the filesystems.
# See fstab(5) for details.

# <file system> <dir> <type> <options> <dump> <pass>
$ROOT_SPEC / $ROOT_FS $ROOT_FSTAB_OPTS 0 $ROOT_FSTAB_PASS
$BOOT_SPEC /boot vfat rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro 0 2
EOF

    if [[ "$TYPE" == "rpi" ]]; then
        echo "Configuring RPi 5 boot (GPT compatible)..."
        echo "root=$ROOT_SPEC rw rootwait console=serial0,115200 console=tty1" > "$ROOT_DIR/boot/cmdline.txt"
    else
        echo "Configuring systemd-boot (UEFI)..."
        # Equivalent of `bootctl install` (which needs a mounted ESP): place the
        # EFI binary at the fallback path and in the systemd-boot directory.
        local EFI_SRC="$ROOT_DIR/usr/lib/systemd/boot/efi/systemd-bootaa64.efi"
        [ -f "$EFI_SRC" ] || { echo "ERROR: $EFI_SRC not found"; return 1; }
        install -Dm755 "$EFI_SRC" "$ROOT_DIR/boot/EFI/BOOT/BOOTAA64.EFI"
        install -Dm755 "$EFI_SRC" "$ROOT_DIR/boot/EFI/systemd/systemd-bootaa64.efi"
        mkdir -p "$ROOT_DIR/boot/loader/entries"

        # Create boot entry
        cat > "$ROOT_DIR/boot/loader/entries/arch.conf" << EOF
title   Arch Linux (Mainline)
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=$ROOT_SPEC rw rootwait console=tty1
EOF

        # Configure loader
        cat > "$ROOT_DIR/boot/loader/loader.conf" << EOF
default arch.conf
timeout 3
console-mode max
EOF
    fi
}

# Function to clean up system before compression
cleanup_system() {
    local ROOT_DIR=$1

    echo "Cleaning up system..."

    # Run as namespaced root: some of these paths are owned by subuids
    # shellcheck disable=SC2016
    ns bash -c '
        d=$1
        [[ -d "$d/var/lib/pacman" ]] && find "$d/var/lib/pacman" -maxdepth 1 -type f -delete
        [[ -d "$d/var/lib/pacman/sync" ]] && find "$d/var/lib/pacman/sync" -delete
        [[ -d "$d/var/cache/pacman/pkg" ]] && find "$d/var/cache/pacman/pkg" -type f -delete
        [[ -d "$d/var/cache" ]] && find "$d/var/cache" -mindepth 1 -delete
        [[ -d "$d/var/log" ]] && find "$d/var/log" -type f -delete
        [[ -d "$d/var/tmp" ]] && find "$d/var/tmp" -mindepth 1 -delete
        [[ -d "$d/etc/pacman.d/gnupg" ]] && find "$d/etc/pacman.d/gnupg" -maxdepth 1 -type s -delete
        rm -f -- "$d/etc/machine-id"
        printf "uninitialized\n" > "$d/etc/machine-id"
        exit 0
    ' _ "$ROOT_DIR"
}

# Function to assemble a GPT disk image from a root tree (with /boot as the ESP/boot partition)
build_disk_image() {
    local ROOT_DIR=$1
    local IMG=$2
    local BOOT_IMG="$WORK/boot.img"
    local ROOT_IMG="$WORK/root.img"
    local BOOT_STAGE="$WORK/bootstage"

    # Start from a fresh file: stale data in a leftover image would survive sparse writes
    rm -f "$IMG"
    truncate -s "$IMG_SIZE" "$IMG"
    sfdisk --quiet "$IMG" << EOF
label: gpt
start=1MiB, size=512MiB, type=U, bootable, uuid=$BOOT_PARTUUID
start=513MiB, type=L, uuid=$ROOT_PARTUUID
EOF

    local ROOT_SECTORS
    ROOT_SECTORS=$(sfdisk -J "$IMG" | jq -r '.partitiontable.partitions[1].size')
    [[ "$ROOT_SECTORS" =~ ^[0-9]+$ ]] || { echo "ERROR: Failed to determine root partition size"; return 1; }

    # Boot partition: FAT32 populated from the staged /boot directory
    # shellcheck disable=SC2016
    ns bash -c 'mv "$1/boot" "$2" && mkdir -m 755 "$1/boot"' _ "$ROOT_DIR" "$BOOT_STAGE"
    truncate -s 512MiB "$BOOT_IMG"
    mkfs.vfat -F32 "$BOOT_IMG" > /dev/null
    # shellcheck disable=SC2016
    ns bash -c 'mcopy -i "$1" -s -m -Q -n "$2"/* ::/' _ "$BOOT_IMG" "$BOOT_STAGE"

    # Root partition: filesystem populated directly from the root tree
    truncate -s $(( ROOT_SECTORS * 512 )) "$ROOT_IMG"
    if [[ "$ROOT_FS" == "btrfs" ]]; then
        ns mkfs.btrfs -q -f --shrink --compress zstd:3 -r "$ROOT_DIR" "$ROOT_IMG"
        # --shrink trims the file to the filesystem size; it must still fit the partition
        if (( $(stat -c %s "$ROOT_IMG") > ROOT_SECTORS * 512 )); then
            echo "ERROR: the btrfs root filesystem does not fit in the root partition; increase the image size" >&2
            exit 1
        fi
        truncate -s $(( ROOT_SECTORS * 512 )) "$ROOT_IMG"
    else
        ns mke2fs -q -F -t ext4 -d "$ROOT_DIR" "$ROOT_IMG"
    fi

    # Write the partition contents at their offsets
    dd if="$BOOT_IMG" of="$IMG" bs=1M seek=1 conv=notrunc,sparse status=none
    dd if="$ROOT_IMG" of="$IMG" bs=1M seek=513 conv=notrunc,sparse status=none
    rm -f "$BOOT_IMG" "$ROOT_IMG"
    ns rm -rf "$BOOT_STAGE"
}

#
# MAIN EXECUTION
#

echo "=== Creating Arch Linux ARM Images ==="
echo "Build date: $BUILD_DATE"
echo "Target types: ${BUILDS[*]}"
echo "Root filesystem: $ROOT_FS"
echo

echo "Note: while packages are installed you may see warnings such as"
echo "  'Possibly missing firmware for module', 'directory permissions differ on .../dev/',"
echo "  'fchownat() ... failed: Operation not permitted', 'No module containing the symbol ...',"
echo "  or (rpi) 'Installing default config.txt' / 'No mounted root device found' (older packages:"
echo "  'Could not determine root filesystem UUID')"
echo "  (this script writes /boot/cmdline.txt itself afterwards)."
echo "  These are expected when building rootless/cross-arch and are harmless."
echo "  A real failure stops the build with a final 'ERROR:' from this script and a non-zero exit code."
echo

# Step 1: Install and configure base system
echo "--- Building base system ---"
install_base_system "$BASE_ROOT"
configure_base_system "$BASE_ROOT"

# Step 2: Build each target from a copy of the base system
for build_type in "${BUILDS[@]}"; do
    echo
    echo "--- Building ${build_type} image ---"
    TARGET_ROOT="$WORK/root-${build_type}"
    TARGET_IMG="$OUTPUT_DIR/archlinux-${build_type}-${BUILD_DATE}-aarch64.img"
    OUTPUT_FILE="$OUTPUT_DIR/archlinux-${build_type}-${BUILD_DATE}-aarch64.img.zst"
    BOOT_PARTUUID=$(uuidgen)
    ROOT_PARTUUID=$(uuidgen)

    echo "Cloning base system..."
    ns cp -a --reflink=auto "$BASE_ROOT" "$TARGET_ROOT"

    # Install kernel and configure boot
    if [[ "$build_type" == "rpi" ]]; then
        echo "Installing linux-rpi5 kernel..."
        pacstrap -N -c -C "$PACMAN_CONF" "$TARGET_ROOT" linux-rpi5 || { echo "ERROR: Failed to install linux-rpi5 kernel"; exit 1; }
    else
        echo "Installing linux kernel..."
        pacstrap -N -c -C "$PACMAN_CONF" "$TARGET_ROOT" linux || { echo "ERROR: Failed to install linux kernel"; exit 1; }
    fi
    configure_boot "$build_type" "$TARGET_ROOT" || { echo "ERROR: Failed to configure ${build_type} boot"; exit 1; }

    cleanup_system "$TARGET_ROOT"

    echo "Assembling ${build_type} disk image..."
    CURRENT_TARGET_IMG="$TARGET_IMG"
    build_disk_image "$TARGET_ROOT" "$TARGET_IMG"
    ns rm -rf "$TARGET_ROOT"

    echo "Compressing ${build_type} image..."
    CURRENT_OUTPUT_FILE="$OUTPUT_FILE"
    zstd -f -9 -T0 "$TARGET_IMG" -o "$OUTPUT_FILE"
    CURRENT_OUTPUT_FILE=""
    rm "$TARGET_IMG"
    CURRENT_TARGET_IMG=""
    echo "Created: ${OUTPUT_FILE}"
done

echo
echo "=== Build Complete ==="
echo "Created images:"
for build_type in "${BUILDS[@]}"; do
    echo "  $OUTPUT_DIR/archlinux-${build_type}-${BUILD_DATE}-aarch64.img.zst"
done
