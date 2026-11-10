# aarch64linux-image-maker

Script to build bootable Arch Linux Aarch64 `.img.zst` images for Raspberry Pi 5
and mainline aarch64 (UEFI/systemd-boot) systems.

## Requirements
A system running Arch Linux (either aarch64 or x86_64).

The script runs **rootless** — no root or sudo needed (it refuses to run as
root). It uses user namespaces (`pacstrap -N`, `arch-chroot -N`) and builds the
filesystems directly from directories, so no loop devices or mounts are used.
One-time host requirements:

- Packages: `arch-install-scripts`, `util-linux`, `shadow`, `pacman`, `gnupg`,
  `wget`, `zstd`, `jq`, `dosfstools`, `mtools`, `e2fsprogs`, `btrfs-progs`
  (plus `qemu-user-static` and `qemu-user-static-binfmt` on non-aarch64 hosts).
  Missing ones are reported with the `pacman -S` command to install them.
- `/etc/subuid` and `/etc/subgid` entries for your user, e.g.
  `usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER`.
- Unprivileged user namespaces enabled (default on Arch).
- Cross-builds: the QEMU aarch64 binfmt handler must be registered
  (`systemctl restart systemd-binfmt`, done by the binfmt package at boot).

## Usage

```bash
./create_image.sh [-o|--output-dir <directory>] [--root-fs ext4|btrfs] [rpi|mainline]
```

- Give at most one target (`rpi` or `mainline`); to build both, omit the target.
  Passing more than one is an error.
- `--root-fs` selects the root filesystem type (`ext4` by default, or `btrfs`).
- `-o/--output-dir` controls where the compressed `.img.zst` files (and
  temporary build files) are written; defaults to the current directory.
- Temporary build files go in a hidden `.aarch64linux-build.*` directory inside
  the output directory (removed on exit, including Ctrl-C). It must be on a
  filesystem that supports Unix ownership/permissions, with roughly 8 GB free.
- Downloaded packages are cached in `${XDG_CACHE_HOME:-~/.cache}/aarch64linux-image-maker/pkg`.

## What it does

1. Installs a minimal Arch Linux base system into a directory and configures
   networking, hostname, and pacman keys (using a private build keyring).
2. Copies that tree once per selected target type.
3. For each copy, installs the appropriate kernel (`linux-rpi5` or `linux`),
   writes `fstab` and configures the bootloader (RPi `cmdline.txt` or
   systemd-boot), cleans up caches/logs/machine-id, builds the GPT image (FAT32
   boot + root filesystem) and compresses it to `.img.zst`.

## Using a larger disk

Images are about 2.5 GB. After flashing to a bigger card or SSD, log in as
root on the running system and run:

    expand-rootfs

It grows the (last) root partition to the end of the disk and then the
filesystem (ext4 or btrfs), online and without a reboot, then deletes itself. `/README_RESIZE.txt` in the image explains the same steps by hand.
The `btrfs` images use zstd compression.

## Expected warnings

Package installation prints some warnings that are harmless when building
rootless and/or cross-arch:

- `Possibly missing firmware for module ...` and `No module containing the
  symbol ...` (mkinitcpio, for hardware or modules the image doesn't target).
- `directory permissions differ on .../dev/`.
- `fchownat() ... failed: Operation not permitted` (systemd hooks touching
  `/sys`).
- RPi only: `Installing default config.txt` (the kernel package's stock
  bootloader config, which is what the image intends to use), followed by
  `No mounted root device found ...` or, with older `linux-rpi5` package
  versions, `ERROR: Could not determine root filesystem UUID`. The package
  hook can't see a mounted root during an image build; the script writes
  `/boot/cmdline.txt` itself afterwards, so this is not fatal.

A real failure stops the build with a final `ERROR:` message from the script
and a non-zero exit code.

## License

MIT — see [LICENSE](LICENSE).
