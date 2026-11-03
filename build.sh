#!/usr/bin/env bash
# Build the CachyOS live ISO with bcachefs support. See README.md.
#
#   ./build.sh            build; remove the ~15 GB work dir on success
#   KEEP_WORK=1 ./build.sh  keep work/ for inspection
#   ./build.sh -v         extra args are passed to upstream buildiso.sh
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$repo/work/src"   # disposable copy of upstream + overlay
out="$repo/out"

msg() { printf '\e[1;32m==>\e[0m \e[1m%s\e[0m\n' "$*"; }
die() { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }

(( EUID != 0 )) || die "run as a normal user (upstream calls sudo itself)"

missing=()
for p in archiso mkinitcpio-archiso squashfs-tools grub git; do
    pacman -Qq "$p" &>/dev/null || missing+=("$p")
done
(( ${#missing[@]} == 0 )) || die "missing build deps, run: sudo pacman -S --needed ${missing[*]}"
# packages are verified with the host's keyring; Arch repos use the host's mirrorlist
pacman -Qq cachyos-keyring &>/dev/null || die "host needs cachyos-keyring (build on CachyOS)"

msg "Syncing upstream submodule (pinned commit)"
git -C "$repo" submodule update --init upstream
rev="$(git -C "$repo/upstream" rev-parse --short HEAD)"

msg "Preparing work tree from upstream $rev"
if [[ -e $src ]]; then
    # previous build leaves root-owned files behind
    sudo rm -rf --one-file-system "$src"
fi
mkdir -p "$src"
git -C "$repo/upstream" archive HEAD | tar -x -C "$src"

msg "Applying overlay"
pkgs="$src/archiso/packages_desktop.x86_64"
[[ -f $pkgs ]] || die "upstream layout changed: $pkgs not found"
mapfile -t kernels < <(grep -E '^linux-cachyos[a-z0-9-]*$' "$pkgs" \
                       | grep -vE -- '-(zfs|nvidia|nvidia-open|headers|dbg)$')
(( ${#kernels[@]} > 0 )) || die "no kernels found in upstream package list"
{
    printf '\n# --- cachyos-bcachefs-iso overlay ---\n'
    printf '%s-headers\n' "${kernels[@]}"
    grep -vE '^[[:space:]]*(#|$)' "$repo/overlay/packages.extra"
} >> "$pkgs"
install -Dm755 "$repo/overlay/customize_airootfs.sh" \
    "$src/archiso/airootfs/root/customize_airootfs.sh"
echo "  kernels: ${kernels[*]}"

msg "Building (upstream buildiso.sh -p desktop)"
args=("$@")
[[ ${KEEP_WORK:-0} == 1 ]] || args+=(-w)
(cd "$src" && ./buildiso.sh -p desktop "${args[@]}")

iso="$(find "$src/out/desktop" -maxdepth 1 -name '*.iso' -print -quit)"
[[ -n $iso ]] || die "build finished but no ISO was produced"

name="$(basename "$iso" .iso)-bcachefs"
mkdir -p "$out"
sudo mv "$iso" "$out/$name.iso"
sudo mv "$src/out/desktop/"*.pkgs.txt "$out/$name.pkgs.txt" 2>/dev/null || true
sudo chown "$USER:" "$out/$name".*
(cd "$out" && sha256sum "$name.iso" > "$name.iso.sha256")
echo "upstream $rev" > "$out/$name.upstream.txt"
[[ ${KEEP_WORK:-0} == 1 ]] || sudo rm -rf --one-file-system "$src"

msg "Done: $out/$name.iso"
