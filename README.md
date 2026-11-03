# cachyos-bcachefs-iso

The official **CachyOS live ISO**, unchanged, plus a working **bcachefs kernel module**
for every kernel on it.

bcachefs was removed from the mainline kernel (6.18+), so stock CachyOS ISOs ship
`bcachefs-tools` but cannot mount bcachefs. That makes them useless for rescuing a
bcachefs system. This repo fixes only that, and stays as close to upstream as possible:

- Upstream [CachyOS-Live-ISO](https://github.com/CachyOS/CachyOS-Live-ISO) is a git
  submodule and is **never patched**. The build runs upstream's own `buildiso.sh`.
- The same desktop, Calamares installer, `cachy-chroot`, kernels (`linux-cachyos` +
  `linux-cachyos-lts`) and drivers as the official ISO.
- The only additions: `bcachefs.ko` for each kernel. The headers and compilers used
  to build it are removed again before the ISO is packed.

Retire this repo once bcachefs is back in the kernel. Until then, rebuild whenever you
want a fresh ISO.

## How it works

```
cachyos-bcachefs-iso/
├── upstream/                   git submodule → CachyOS/CachyOS-Live-ISO (pinned commit)
├── overlay/
│   ├── packages.extra          extra packages (bcachefs-dkms)
│   └── customize_airootfs.sh   verify module + strip build toolchain (runs in ISO chroot)
├── build.sh                    copy upstream → apply overlay → run upstream buildiso.sh
└── .github/workflows/
    └── upstream-bump.yml       weekly PR when upstream has new commits
```

`build.sh`:

1. Exports the pinned `upstream/` commit into `work/src/`. The submodule itself is
   never modified.
2. Appends to `archiso/packages_desktop.x86_64`:
   - `<kernel>-headers` for every `linux-cachyos*` kernel in upstream's list (found
     automatically, so a new kernel added upstream is picked up)
   - everything in `overlay/packages.extra`
3. Drops `overlay/customize_airootfs.sh` into `airootfs/root/`.
4. Runs `./buildiso.sh -p desktop`, the same command CachyOS uses.

During the archiso build, pacman's DKMS hook compiles `bcachefs.ko` for each kernel.
Then `customize_airootfs.sh` runs inside the ISO root and:

1. **Fails the whole build** if any kernel lacks a bcachefs module. You can never end
   up with a "bcachefs" ISO that can't mount bcachefs.
2. Removes `bcachefs-dkms`, the kernel headers and their now-unneeded dependencies
   (dkms, rust, clang/llvm/lld, ...). This saves about 1.5 GB unpacked. The DKMS
   remove hook is masked for that step, so the built modules stay.
3. Runs `depmod` and verifies again.

The result is `out/cachyos-desktop-linux-<YYMMDD>-bcachefs.iso`.

## Requirements

- **A CachyOS host.** Packages are verified with the host's `cachyos-keyring`, and the
  Arch repos use the host's `/etc/pacman.d/mirrorlist`.
- Build dependencies:
  ```sh
  sudo pacman -S --needed git archiso mkinitcpio-archiso squashfs-tools grub
  ```
- Optional, for testing in a VM:
  ```sh
  sudo pacman -S --needed qemu-desktop edk2-ovmf
  ```
- About 20 GB of free disk space in the repo directory, and `sudo` rights. `mkarchiso`
  must run as root. Upstream's scripts call `sudo` themselves, so run `build.sh` as
  your normal user.
- A network connection. All packages are downloaded fresh from the CachyOS/Arch repos.

> Note: upstream's build script patches `/usr/bin/mkarchiso` on the host (disables the
> archlinux keyring sync timer, and enables verbose mode with `-v`). This is upstream
> behaviour, and it is undone whenever the `archiso` package is reinstalled or updated.

## Building

```sh
git clone --recurse-submodules https://github.com/Gigas002/cachyos-bcachefs-iso.git
cd cachyos-bcachefs-iso
./build.sh
```

Takes roughly 30 to 60 minutes. Look for these lines in the output:

```
bcachefs-iso: 7.x.y-z-cachyos -> /usr/lib/modules/.../updates/dkms/bcachefs.ko.zst (...)
bcachefs-iso: 6.18.y-z-cachyos-lts -> ...
```

Output in `out/`:

| file | |
|---|---|
| `*-bcachefs.iso` | the ISO |
| `*-bcachefs.iso.sha256` | checksum |
| `*-bcachefs.pkgs.txt` | exact package versions on the ISO |
| `*-bcachefs.upstream.txt` | upstream commit it was built from |

Options:

- `KEEP_WORK=1 ./build.sh` keeps `work/` (about 15 GB) after a successful build, for
  debugging. By default it is deleted. After a failed build it is always kept, and the
  next run wipes it.
- `./build.sh -v` and any other arguments are passed to upstream `buildiso.sh`
  (`-v` verbose log, `-r` build in RAM if you have more than 23 GB of RAM).

## Publishing a release

```sh
./release.sh            # newest out/*-bcachefs.iso → GitHub release tagged <YYMMDD>
```

GitHub release files are limited to 2 GiB, so `release.sh` splits the ISO into parts
smaller than that. It uploads them together with `.parts.sha256`, `.iso.sha256` and
the package list, and writes the release notes (kernel and bcachefs versions, upstream
commit). Requires `gh auth login`.

Downloading a release:

```sh
sha256sum -c *.parts.sha256
iso=$(basename *.iso.sha256 .sha256)
cat "$iso".part* > "$iso"
sha256sum -c "$iso.sha256"
```

## Testing in a VM

`run_archiso` comes with `archiso`:

```sh
run_archiso -u -i out/cachyos-desktop-linux-*-bcachefs.iso   # UEFI
run_archiso    -i out/cachyos-desktop-linux-*-bcachefs.iso   # BIOS
```

In the live system, check both kernels (the LTS one is the "fallback" boot entry):

```sh
sudo modprobe bcachefs && lsmod | grep bcachefs
modinfo -F version bcachefs
truncate -s 1G /tmp/t.img && bcachefs format /tmp/t.img \
  && sudo mount -t bcachefs /tmp/t.img /mnt && findmnt /mnt && sudo umount /mnt
```

## Writing to USB

```sh
lsblk                                   # find the stick, e.g. /dev/sdX — double check!
sudo dd if=out/cachyos-desktop-linux-*-bcachefs.iso of=/dev/sdX bs=4M oflag=direct status=progress conv=fsync
```

Ventoy also works.

## Rescuing a bcachefs system

Boot the ISO, then either:

- run **`cachy-chroot`** (CachyOS's chroot helper, same as on the official ISO) and pick
  your root partition. Load the module first with `sudo modprobe bcachefs`, so the
  partition can be mounted. Or:
- mount it by hand:
  ```sh
  sudo modprobe bcachefs
  sudo bcachefs unlock /dev/nvme0n1p2          # only if encrypted
  sudo mount -t bcachefs /dev/nvme0n1p2 /mnt    # multi-device: /dev/sda:/dev/sdb
  sudo mount /dev/nvme0n1p1 /mnt/boot           # your ESP
  sudo arch-chroot /mnt
  ```

Inside the chroot, the installed system's own toolchain is used, so you can
reinstall kernels or rebuild `bcachefs-dkms` normally (`pacman -S linux-cachyos
linux-cachyos-headers bcachefs-dkms`).

Filesystem repair from the live system: `sudo bcachefs fsck /dev/...`.

> The ISO's `bcachefs-tools` and the module come from the repos at build time. Rebuild
> the ISO now and then so it does not lag behind the on-disk format version your
> installed system uses. A new filesystem version may need a newer module to mount
> read-write.

## Updating

Everything except upstream's scripts is fetched fresh at build time: kernels,
`bcachefs-dkms`, `bcachefs-tools` and all packages. **Just rebuilding gives you an
up-to-date ISO.**

To also pick up changes to CachyOS's ISO profile (package list, configs, boot menu):

- **Automatic:** the *Bump upstream* workflow runs weekly (or by hand from the Actions
  tab) and opens a PR when upstream has new commits. Review the linked compare, merge
  it, then:
  ```sh
  git pull && git submodule update --init && ./build.sh
  ```
- **By hand:**
  ```sh
  git submodule update --init --remote upstream
  git -C upstream log --oneline -10       # see what changed
  ./build.sh                              # test first
  git commit -am "Bump upstream" && git push
  ```

Upstream changes that can break the overlay (`build.sh` fails early with a clear error
for most of them):

- `archiso/packages_desktop.x86_64` renamed, or profile name `desktop` changed
- kernel packages renamed away from `linux-cachyos*`
- `buildiso.sh` flags or output dir (`out/desktop/`) changed
- archiso dropping `customize_airootfs.sh` support (currently deprecated but working).
  The fallback would be running the overlay script from a pacman hook.

To go back to a known-good upstream commit: `git -C upstream checkout <commit>`, then
`./build.sh`.

## Troubleshooting

**`bcachefs module MISSING for kernel X`.** DKMS failed to build for that kernel.
Usually a brand-new kernel that the released `bcachefs-dkms` doesn't support yet.
Scroll up for the DKMS error (or rerun with `-v` and check the log). Options:

- wait a few days for a `bcachefs-dkms` update and rebuild, or
- switch to the git version: in `overlay/packages.extra`, replace `bcachefs-dkms` with
  `bcachefs-dkms-git`. If the git module needs matching git tools, add
  `bcachefs-tools-git` as well. It conflicts with upstream's `bcachefs-tools`, so the
  build may then need that line removed from the copied package list in `build.sh`.

**Build aborted, leftover mounts.** `findmnt | grep work/` and `sudo umount -R` them,
then rerun.

**Out of disk space.** The build needs about 20 GB. `work/` is deleted after success
unless you set `KEEP_WORK=1`.

**Stale package/keyring errors.** `sudo pacman -Syu` on the host first.

## When bcachefs returns to the kernel

Check with `modinfo -F filename bcachefs` on a stock CachyOS ISO. If it reports a path
outside `updates/dkms`, the stock ISO is all you need and this repo can be archived.
