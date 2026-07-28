# aarch64linux-image-maker

Script to build bootable Arch Linux ARM `.img.zst` images for Raspberry Pi 5
and mainline aarch64 (UEFI/systemd-boot) systems.

## Usage

```bash
sudo ./create_image.sh [-o|--output-dir <directory>] [--root-fs ext4|btrfs] [rpi|mainline]
```

- Must be run as root.
- If no target (`rpi` or `mainline`) is given, both image types are built.
- `--root-fs` selects the root filesystem type (`ext4` by default, or `btrfs`).
- `-o/--output-dir` controls where the compressed `.img.zst` files (and
  temporary build images) are written; defaults to the current directory.

Missing host dependencies (`arch-install-scripts`, `multipath-tools`, `wget`,
`zstd`, `jq`, `gptfdisk`, `dosfstools`, `e2fsprogs`, `btrfs-progs`) are
detected and installed automatically.

## What it does

1. Creates a temporary GPT base image, partitions it (FAT32 boot + root
   filesystem), installs a minimal Arch Linux base system, and configures
   networking, hostname, and pacman keys.
2. Clones the base image once per selected target type.
3. For each clone, installs the appropriate kernel (`linux-rpi5` or `linux`),
   configures the bootloader (RPi `cmdline.txt` or systemd-boot), cleans up
   caches/logs/machine-id, and compresses the result to `.img.zst`.

Each built image includes a `README_RESIZE.txt` with instructions for
expanding the root filesystem to fill larger media after flashing.

## License

MIT — see [LICENSE](LICENSE).
