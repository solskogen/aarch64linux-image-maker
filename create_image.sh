#!/bin/bash
# Description: Script to create both RPi5 and Mainline AArch64 Arch Linux images efficiently.
# Usage: ./create_image.sh [-o|--output-dir <dir>] [--root-fs ext4|btrfs] {rpi|mainline}  (If no argument provided, builds both by default)
set -e
set -o pipefail

usage() {
    cat <<'EOF'
Usage: ./create_image.sh [-o|--output-dir <directory>] [--root-fs ext4|btrfs] [rpi|mainline]

If no target is provided, both image types are built.
--root-fs defaults to ext4.
EOF
}

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
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --root-fs)
            ROOT_FS="$2"
            shift 2
            ;;
        rpi|mainline)
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

# Detect host architecture for cross-compilation support
HOST_ARCH=$(uname -m)
CROSS_BUILD=false
if [[ "$HOST_ARCH" != "aarch64" ]]; then
    CROSS_BUILD=true
    echo "Host architecture: $HOST_ARCH — will cross-build aarch64 images using QEMU"
fi

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root"
   exit 1
fi

# Check for required dependencies
declare -A REQUIRED_COMMAND_PACKAGES=(
    [pacstrap]=arch-install-scripts
    [genfstab]=arch-install-scripts
    [arch-chroot]=arch-install-scripts
    [kpartx]=multipath-tools
    [wget]=wget
    [zstd]=zstd
    [jq]=jq
    [sfdisk]=util-linux
    [sgdisk]=gptfdisk
    [mkfs.vfat]=dosfstools
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
    echo "Installing missing packages: ${MISSING_PACKAGES[*]}"
    pacman -Sy --needed --noconfirm "${MISSING_PACKAGES[@]}"
fi

# Repository configuration (single source of truth for the custom aarch64 repo)
REPO_BASE_URL="https://arch-linux-repo.drzee.net/arch"
REPO_SIGNING_KEY="0CF25682E6BA0751"

# Import repository signing key into host keyring (needed for pacstrap)
echo "Importing repository signing key..."
wget --timeout=30 -qO "$(pwd)/public.key" "$REPO_BASE_URL/extra/os/aarch64/public.key" || { echo "ERROR: Failed to download repository signing key"; exit 1; }
pacman-key --add "$(pwd)/public.key" || { echo "ERROR: Failed to import repository signing key"; exit 1; }
pacman-key --lsign-key "$REPO_SIGNING_KEY" || { echo "ERROR: Failed to locally sign repository key"; exit 1; }

# Set up QEMU user-mode emulation for cross-building
if $CROSS_BUILD; then
    echo "Setting up QEMU aarch64 emulation..."
    systemctl restart systemd-binfmt 2>/dev/null || true
    if [[ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
        echo "ERROR: QEMU aarch64 binfmt_misc registration failed"
        echo "Ensure binfmt_misc support is enabled in your kernel"
        exit 1
    fi
    echo "QEMU aarch64 emulation is active"
fi

# Create custom pacman.conf for aarch64 target packages
PACMAN_CONF=$(mktemp)
cat > "$PACMAN_CONF" << CONFEOF
[options]
HoldPkg = pacman glibc
Architecture = aarch64
CheckSpace
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
ParallelDownloads = 5

[forge]
Server = $REPO_BASE_URL/\$repo/os/\$arch

[core]
Server = $REPO_BASE_URL/\$repo/os/\$arch

[extra]
Server = $REPO_BASE_URL/\$repo/os/\$arch
CONFEOF

# Configuration
MNT=$(mktemp -d)
IMG_SIZE="2500M"
BUILD_DATE=$(date +%Y.%m.%d)

# Global variables for cleanup tracking
BASE_LOOP_NAME=""
CURRENT_LOOP_NAME=""
CURRENT_TARGET_IMG=""
CURRENT_OUTPUT_FILE=""

# Cleanup function for exit/failure/interrupt
cleanup() {
    echo "Running cleanup function..."
    
    # Unmount directories
    if mountpoint -q "$MNT"; then
        echo "Unmounting $MNT..."
        pkill -f "gpg-agent.*$MNT" 2>/dev/null || true
        umount "$MNT/boot" 2>/dev/null || true
        umount "$MNT" 2>/dev/null || true
    fi
    if [ -d "$MNT" ]; then
        rmdir "$MNT" 2>/dev/null || true
    fi

    # Detach loop devices
    if [ -n "$BASE_LOOP_NAME" ]; then
        echo "Detaching base loop mappings..."
        kpartx -dv "$BASE_IMG" 2>/dev/null || true
    fi
    if [ -n "$CURRENT_LOOP_NAME" ] && [ -n "$CURRENT_TARGET_IMG" ]; then
        echo "Detaching current loop mappings..."
        kpartx -dv "$CURRENT_TARGET_IMG" 2>/dev/null || true
    fi

    # Remove incomplete image/compressed output left behind by an interrupted run.
    # These are only cleared (see below) once they reach a known-good final state.
    if [ -n "$CURRENT_TARGET_IMG" ] && [ -f "$CURRENT_TARGET_IMG" ]; then
        echo "Removing incomplete image $CURRENT_TARGET_IMG..."
        rm -f "$CURRENT_TARGET_IMG"
    fi
    if [ -n "$CURRENT_OUTPUT_FILE" ] && [ -f "$CURRENT_OUTPUT_FILE" ]; then
        echo "Removing incomplete compressed output $CURRENT_OUTPUT_FILE..."
        rm -f "$CURRENT_OUTPUT_FILE"
    fi

    # Remove leftover repository key
    rm -f "$(pwd)/public.key"

    # Remove temporary pacman config
    [[ -n "${PACMAN_CONF:-}" ]] && rm -f "$PACMAN_CONF"
}

# Set up cleanup trap
trap cleanup EXIT INT TERM

# Determine which images to build
if [[ "$TARGET_TYPE" != "rpi" && "$TARGET_TYPE" != "mainline" && "$TARGET_TYPE" != "" ]]; then
    usage
    exit 1
fi

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

BASE_IMG="$OUTPUT_DIR/aarch64linux-base.img"

if [[ "$TARGET_TYPE" == "rpi" ]]; then
    BUILDS=("rpi")
elif [[ "$TARGET_TYPE" == "mainline" ]]; then
    BUILDS=("mainline")
else
    BUILDS=("rpi" "mainline") # Build both by default
fi

# Preflight disk space check: base image + one raw clone per target must fit,
# with some headroom for the compressed .zst output created alongside a clone.
IMG_SIZE_MB=${IMG_SIZE%M}
REQUIRED_MB=$(( IMG_SIZE_MB * (${#BUILDS[@]} + 1) + IMG_SIZE_MB / 2 ))
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

# Function to mount existing image without reformatting
mount_existing_image() {
    local IMG=$1
    local MNT_DIR=$2

    [ -f "$IMG" ] || { echo "ERROR: Image file $IMG does not exist"; return 1; }

    # Create loop device mappings
    local KPARTX_OUTPUT
    KPARTX_OUTPUT=$(kpartx -av "$IMG")
    local LOOP_NAME
    LOOP_NAME=$(echo "$KPARTX_OUTPUT" | head -1 | awk '{print $3}' | sed 's/p[0-9]*$//')
    
    [ -n "$LOOP_NAME" ] || { echo "ERROR: Failed to extract loop device name" >&2; return 1; }
    
    udevadm settle
    
    local BOOT_PART="/dev/mapper/${LOOP_NAME}p1"
    local ROOT_PART="/dev/mapper/${LOOP_NAME}p2"

    # Verify partitions exist
    [ -b "$BOOT_PART" ] || { echo "ERROR: Boot partition $BOOT_PART not found" >&2; return 1; }
    [ -b "$ROOT_PART" ] || { echo "ERROR: Root partition $ROOT_PART not found" >&2; return 1; }

    # Mount filesystems (explicit -t avoids kernel fs autoprobing noise in dmesg)
    mkdir -p "$MNT_DIR"
    mount -t "$ROOT_FS" "$ROOT_PART" "$MNT_DIR"
    mkdir -p "$MNT_DIR/boot"
    mount -t vfat "$BOOT_PART" "$MNT_DIR/boot"
    
    echo "$LOOP_NAME"
}

# Function to setup GPT partitions, format filesystems, and mount
setup_partitions_and_mount() {
    local IMG=$1
    local MNT_DIR=$2

    [ -f "$IMG" ] || { echo "ERROR: Image file $IMG does not exist"; return 1; }

    # Create GPT partition table
    if ! sfdisk "$IMG" >&2 << 'EOF'; then
label: gpt
1MiB,512MiB,U,*
513MiB,,L
EOF
        echo "ERROR: Failed to partition $IMG"
        return 1
    fi

    # Create loop device mappings
    local KPARTX_OUTPUT
    KPARTX_OUTPUT=$(kpartx -av "$IMG")
    local LOOP_NAME
    LOOP_NAME=$(echo "$KPARTX_OUTPUT" | head -1 | awk '{print $3}' | sed 's/p[0-9]*$//')
    
    [ -n "$LOOP_NAME" ] || { echo "ERROR: Failed to extract loop device name" >&2; return 1; }
    
    udevadm settle
    
    local BOOT_PART="/dev/mapper/${LOOP_NAME}p1"
    local ROOT_PART="/dev/mapper/${LOOP_NAME}p2"

    # Verify partitions exist
    [ -b "$BOOT_PART" ] || { echo "ERROR: Boot partition $BOOT_PART not found" >&2; return 1; }
    [ -b "$ROOT_PART" ] || { echo "ERROR: Root partition $ROOT_PART not found" >&2; return 1; }

    # Format filesystems
    mkfs.vfat -F32 "$BOOT_PART" > /dev/null || { echo "ERROR: Failed to format boot partition" >&2; return 1; }
    if [[ "$ROOT_FS" == "btrfs" ]]; then
        mkfs.btrfs -f "$ROOT_PART" > /dev/null || { echo "ERROR: Failed to format root partition" >&2; return 1; }
    else
        mkfs.ext4 "$ROOT_PART" > /dev/null || { echo "ERROR: Failed to format root partition" >&2; return 1; }
    fi

    # Mount filesystems (explicit -t avoids kernel fs autoprobing noise in dmesg)
    mkdir -p "$MNT_DIR"
    mount -t "$ROOT_FS" "$ROOT_PART" "$MNT_DIR"
    mount -t vfat --mkdir "$BOOT_PART" "$MNT_DIR/boot"
    
    echo "$LOOP_NAME"
}

# Function to configure bootloader for specific target type
configure_boot() {
    local TYPE=$1
    local ROOT_SPEC=$2
    local MNT_DIR=$3

    # Generate fstab
    genfstab -t PARTUUID -f "$MNT_DIR" "$MNT_DIR" > "$MNT_DIR/etc/fstab"

    if [[ "$TYPE" == "rpi" ]]; then
        echo "Configuring RPi 5 boot (GPT compatible)..."
        echo "root=$ROOT_SPEC rw rootwait console=serial0,115200 console=tty1" | tee "$MNT_DIR/boot/cmdline.txt" > /dev/null
    else
        echo "Configuring systemd-boot (UEFI)..."
        if arch-chroot -S "$MNT_DIR" bootctl install; then
            echo "bootctl install completed successfully"
        else
            echo "ERROR: bootctl install failed with exit code $?"
            return 1
        fi
        
        # Create boot entry
        tee "$MNT_DIR/boot/loader/entries/arch.conf" << EOF
title   Arch Linux (Mainline)
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=$ROOT_SPEC rw rootwait console=tty1
EOF
        
        # Configure loader
        tee "$MNT_DIR/boot/loader/loader.conf" << EOF
default arch.conf
timeout 3
console-mode max
EOF
    fi
}

# Function to install base system
install_base_system() {
    local MNT_DIR=$1
    
    echo "Installing base system..."
    if ! pacstrap -c -C "$PACMAN_CONF" "$MNT_DIR" base vim btrfs-progs dosfstools e2fsprogs arch-install-scripts linux-firmware mkinitcpio; then
        echo "ERROR: pacstrap install failed"
        exit 1
    fi

    # Verify installation
    [ -f "$MNT_DIR/etc/pacman.conf" ] || { echo "ERROR: Base system installation incomplete"; exit 1; }
}

# Function to configure base system
configure_base_system() {
    local MNT_DIR=$1
    
    echo "Configuring base system..."

    # /etc/pacman.conf inside the image is provided by our own pacman package
    # (installed via pacstrap) and is left completely untouched.

    # Network configuration
    rm "$MNT_DIR/etc/resolv.conf"
    ln -s /run/systemd/resolve/stub-resolv.conf "$MNT_DIR/etc/resolv.conf"
    ln -sf ../../../../usr/lib/systemd/system/multi-user.target "$MNT_DIR/etc/systemd/system/default.target"

    # System settings
    echo "aarch64linux" | tee "$MNT_DIR/etc/hostname" > /dev/null
    passwd --root "$MNT_DIR" -d root > /dev/null
    systemctl --root="$MNT_DIR" enable systemd-networkd systemd-resolved > /dev/null
    
    # Network configuration
    mkdir -p "$MNT_DIR/etc/systemd/network"
    tee "$MNT_DIR/etc/systemd/network/20-wired.network" << 'EOF' > /dev/null
[Match]
Name=e*
[Network]
DHCP=yes
EOF

    # Install repository public key (reuse downloaded key if available)
    if [ ! -f "$(pwd)/public.key" ]; then
        wget --timeout=30 -O "$(pwd)/public.key" "$REPO_BASE_URL/extra/os/aarch64/public.key"
    fi
    cp "$(pwd)/public.key" "$MNT_DIR/root/"
    arch-chroot "$MNT_DIR" pacman-key --init
    arch-chroot "$MNT_DIR" pacman-key --populate
    arch-chroot "$MNT_DIR" pacman-key --add /root/public.key
    arch-chroot "$MNT_DIR" pacman-key --lsign-key "$REPO_SIGNING_KEY"
    rm "$(pwd)/public.key"

    # Create README file (resize instructions depend on the root filesystem type)
    if [[ "$ROOT_FS" == "btrfs" ]]; then
        RESIZE_STEP=$(cat <<'STEPEOF'
3.  **Expand the filesystem.**
    Btrfs can grow online to fill the partition while it is mounted, so no
    unmount is needed. Run this from within the mounted root filesystem (`/`).

    ```bash
    # Grows the mounted filesystem at / to fill its partition
    sudo btrfs filesystem resize max /
    ```
STEPEOF
)
    else
        RESIZE_STEP=$(cat <<'STEPEOF'
3.  **Expand the filesystem.**
    Once the partition size is updated by the kernel, use `resize2fs` to resize the ext4 filesystem inside that partition. This can often be done while the filesystem is mounted.

    ```bash
    # Example for partition /dev/mmcblk0p2
    sudo resize2fs /dev/mmcblk0p2
    ```
STEPEOF
)
    fi

    {
        cat <<EOF
# How to Expand the Root Filesystem to Match Your Media (GPT Images)

Once you have flashed the '.img.zst' file to your SD card or SSD (e.g., using \`dd\` or Raspberry Pi Imager), the image will only use ~2GB of space. To use the entire capacity of your media, follow these steps while running the installed system.

This image's root filesystem is: $ROOT_FS

These commands assume your root partition is the second partition on the disk (e.g., /dev/mmcblk0p2 or /dev/sda2). You must run these commands as root or with \`sudo\`.

## Steps

1.  **Identify your device and root partition number.**
    Run \`lsblk\` to find your physical disk name (e.g., \`mmcblk0\`, \`sda\`) and your root partition number (e.g., \`2\`).

2.  **Expand the partition table.**
    Use \`sfdisk\` to resize the root partition to fill all available space on the disk. \`sfdisk\` is part of \`util-linux\`, which is already installed, so no extra packages are needed. This works even while the partition is mounted, since modern \`sfdisk\` tells the running kernel about the new size itself (the same mechanism tools like \`growpart\` use internally) — as long as you are growing (not shrinking) the last partition on the disk.

    \`\`\`bash
    # Example for device /dev/mmcblk0, partition number 2
    # The ", +" tells sfdisk to keep the start of partition 2 and grow it
    # to fill the rest of the disk.
    echo ', +' | sudo sfdisk --no-reread -N 2 /dev/mmcblk0
    \`\`\`

    If you see a warning that the kernel could not be informed of the change,
    reboot once before continuing to the next step.

EOF
        printf '%s\n\n' "$RESIZE_STEP"
        cat <<'EOF'
4.  **Verify.**
    Run `df -h` or `lsblk` again to confirm that your root filesystem now uses the full available space.
EOF
    } > "$MNT_DIR/README_RESIZE.txt"

    # Optimize mkinitcpio configuration
    # These images are meant to run on varied hardware, so drop autodetect
    # (which trims hooks/modules to the build host) and microcode (CPU-specific).
    sed -i '/^HOOKS=/s/autodetect //' "$MNT_DIR/etc/mkinitcpio.conf"
    sed -i '/^HOOKS=/s/microcode //' "$MNT_DIR/etc/mkinitcpio.conf"
    
    # Create vconsole.conf to prevent systemd warnings
    touch "$MNT_DIR/etc/vconsole.conf"
}

# Function to clean up system before compression
cleanup_system() {
    local MNT_DIR=$1
    
    echo "Cleaning up system..."
    
    # Kill any remaining processes
    pkill -f "gpg-agent.*$MNT_DIR" 2>/dev/null || true
    
    # Clean package cache and logs
    [[ -d "${MNT_DIR}/var/lib/pacman" ]] && find "${MNT_DIR}/var/lib/pacman" -maxdepth 1 -type f -delete
    [[ -d "${MNT_DIR}/var/lib/pacman/sync" ]] && find "${MNT_DIR}/var/lib/pacman/sync" -delete
    [[ -d "${MNT_DIR}/var/cache/pacman/pkg" ]] && find "${MNT_DIR}/var/cache/pacman/pkg" -type f -delete
    [[ -d "${MNT_DIR}/var/cache" ]] && find "${MNT_DIR}/var/cache" -mindepth 1 -delete
    [[ -d "${MNT_DIR}/var/log" ]] && find "${MNT_DIR}/var/log" -type f -delete
    [[ -d "${MNT_DIR}/var/tmp" ]] && find "${MNT_DIR}/var/tmp" -mindepth 1 -delete

    # Reset machine ID
    rm -f -- "${MNT_DIR}/etc/machine-id"
    printf 'uninitialized\n' >"${MNT_DIR}/etc/machine-id"
}

# Function to get partition UUID
get_partition_uuid() {
    local IMG=$1
    local LOOP_NAME=$2
    
    # Try to get PARTUUID from partition table
    local PARTUUID
    PARTUUID=$(sfdisk -J "$IMG" | jq -r '.partitiontable.partitions[1].uuid' 2>/dev/null)
    
    if [ -z "$PARTUUID" ] || [ "$PARTUUID" = "null" ]; then
        PARTUUID=$(sgdisk -i 2 "$IMG" 2>/dev/null | grep "Partition unique GUID" | awk '{print $4}')
    fi
    
    if [ -z "$PARTUUID" ] || [ "$PARTUUID" = "null" ]; then
        local ROOT_PART="/dev/mapper/${LOOP_NAME}p2"
        local ROOT_UUID
        ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART" 2>/dev/null)
        if [ -n "$ROOT_UUID" ]; then
            echo "UUID=$ROOT_UUID"
            return 0
        fi
    fi

    # Ensure lowercase for GUID-based identifiers
    PARTUUID=$(echo "$PARTUUID" | tr '[:upper:]' '[:lower:]')
    
    if [ -z "$PARTUUID" ]; then
        echo "ERROR: Failed to get any UUID"
        exit 1
    fi
    
    echo "PARTUUID=$PARTUUID"
}

#
# MAIN EXECUTION
#

echo "=== Creating Arch Linux ARM Images ==="
echo "Build date: $BUILD_DATE"
echo "Target types: ${BUILDS[*]}"
echo "Root filesystem: $ROOT_FS"
echo

# Step 1: Create base image
echo "--- Building temporary base image: $BASE_IMG ---"
rm -f "$BASE_IMG"
truncate -s "$IMG_SIZE" "$BASE_IMG" || { echo "ERROR: Failed to create base image file"; exit 1; }
[ -f "$BASE_IMG" ] || { echo "ERROR: Base image file was not created"; exit 1; }

BASE_LOOP_NAME=$(setup_partitions_and_mount "$BASE_IMG" "$MNT") || { 
    echo "ERROR: Failed to setup partitions for base image"; exit 1; 
}

# Step 2: Install and configure base system
install_base_system "$MNT"
configure_base_system "$MNT"

# Step 3: Unmount base image
echo "Unmounting base image..."
umount "$MNT/boot"
umount "$MNT"
kpartx -dv "$BASE_IMG"
BASE_LOOP_NAME=""

# Step 4: Clone base image for each target type
echo
echo "--- Cloning base images ---"
for build_type in "${BUILDS[@]}"; do
    TARGET_IMG="$OUTPUT_DIR/archlinux-${build_type}-${BUILD_DATE}-aarch64.img"
    CURRENT_TARGET_IMG="$TARGET_IMG"
    echo "Cloning to ${TARGET_IMG}..."
    cp --sparse=always "$BASE_IMG" "$TARGET_IMG"
done

# Step 5: Customize each cloned image
echo
echo "--- Customizing images ---"
for build_type in "${BUILDS[@]}"; do
    TARGET_IMG="$OUTPUT_DIR/archlinux-${build_type}-${BUILD_DATE}-aarch64.img"
    CURRENT_TARGET_IMG="$TARGET_IMG"
    
    echo "Customizing ${build_type} image..."

    CURRENT_LOOP_NAME=$(mount_existing_image "$TARGET_IMG" "$MNT")
    
    # Verify mount
    [ -f "$MNT/etc/pacman.conf" ] || { echo "ERROR: Cloned system not properly mounted"; exit 1; }
    [ -d "$MNT/proc" ] || { echo "ERROR: /proc directory missing in cloned system"; exit 1; }
    if ! { [ -d "$MNT" ] && mountpoint -q "$MNT"; }; then
        echo "ERROR: Mount point not valid"
        exit 1
    fi
    
    # Get partition UUID
    PARTUUID=$(get_partition_uuid "$CURRENT_TARGET_IMG" "$CURRENT_LOOP_NAME")
    
    # Install kernel and configure boot
    if [[ "$build_type" == "rpi" ]]; then
        echo "Installing linux-rpi5 kernel..."
        arch-chroot "$MNT" pacman -S linux-rpi5 --noconfirm --disable-sandbox || { echo "ERROR: Failed to install linux-rpi5 kernel"; exit 1; }
        configure_boot rpi "$PARTUUID" "$MNT" || { echo "ERROR: Failed to configure rpi boot"; exit 1; }
    else
        echo "Installing linux kernel..."
        arch-chroot "$MNT" pacman -S linux --noconfirm --disable-sandbox || { echo "ERROR: Failed to install linux kernel"; exit 1; }
        configure_boot mainline "$PARTUUID" "$MNT" || { echo "ERROR: Failed to configure mainline boot"; exit 1; }
    fi

    # Clean up and compress
    cleanup_system "$MNT"
    sync
    sleep 1
    umount "$MNT/boot"
    umount "$MNT"
    kpartx -dv "$TARGET_IMG"
    CURRENT_LOOP_NAME=""
    
    echo "Compressing ${build_type} image..."
    OUTPUT_FILE="$OUTPUT_DIR/archlinux-${build_type}-${BUILD_DATE}-aarch64.img.zst"
    CURRENT_OUTPUT_FILE="$OUTPUT_FILE"
    zstd -f -9 -T0 "$TARGET_IMG" -o "$OUTPUT_FILE"
    CURRENT_OUTPUT_FILE=""
    rm "$TARGET_IMG"
    CURRENT_TARGET_IMG=""
    echo "Created: ${OUTPUT_FILE}"
done

# Step 6: Final cleanup
echo
echo "--- Final cleanup ---"
if [ -f "$BASE_IMG" ]; then 
    rm "$BASE_IMG"
fi

echo
echo "=== Build Complete ==="
echo "Created images:"
for build_type in "${BUILDS[@]}"; do
    echo "  $OUTPUT_DIR/archlinux-${build_type}-${BUILD_DATE}-aarch64.img.zst"
done
