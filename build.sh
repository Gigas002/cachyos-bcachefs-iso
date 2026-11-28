#!/usr/bin/env bash
# Build the CachyOS live ISOs with bcachefs support. See README.md.
#
#   ./build.sh               build both flavours: desktop and minimal
#   ./build.sh desktop       upstream's desktop ISO + bcachefs
#   ./build.sh minimal       console-only ISO with the cachyinstall installer
#   KEEP_WORK=1 ./build.sh   keep work/ of the last flavour built, for inspection (~15 GB)
#   ./build.sh minimal -v    arguments after the flavour go to upstream buildiso.sh
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$repo/work/src"   # disposable copy of upstream + overlay
out="$repo/out"

msg() { printf '\e[1;32m==>\e[0m \e[1m%s\e[0m\n' "$*"; }
warn() { printf '\e[1;33m==> WARNING:\e[0m %s\n' "$*" >&2; }
die() { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }

flavours=(desktop minimal)
case "${1:-all}" in
    all) shift $(( $# > 0 ? 1 : 0 )) ;;
    desktop|minimal) flavours=("$1"); shift ;;
    -*) ;;   # old usage: ./build.sh -v
    *) die "unknown flavour '$1' (desktop, minimal or all)" ;;
esac

(( EUID != 0 )) || die "run as a normal user (upstream calls sudo itself)"

missing=()
for p in archiso mkinitcpio-archiso squashfs-tools grub git; do
    pacman -Qq "$p" &>/dev/null || missing+=("$p")
done
[[ " ${flavours[*]} " != *" minimal "* ]] || command -v cargo &>/dev/null || missing+=(rust)
(( ${#missing[@]} == 0 )) || die "missing build deps, run: sudo pacman -S --needed ${missing[*]}"
# packages are verified with the host's keyring; Arch repos use the host's mirrorlist
pacman -Qq cachyos-keyring &>/dev/null || die "host needs cachyos-keyring (build on CachyOS)"

msg "Syncing submodules (pinned commits)"
git -C "$repo" submodule update --init upstream
rev="$(git -C "$repo/upstream" rev-parse --short HEAD)"

if [[ " ${flavours[*]} " == *" minimal "* ]]; then
    git -C "$repo" submodule update --init cachyinstall
    msg "Building cachyinstall $(git -C "$repo/cachyinstall" rev-parse --short HEAD)"
    cargo build --release --locked --manifest-path "$repo/cachyinstall/Cargo.toml" \
        --target-dir "$repo/work/cargo"
    installer="$repo/work/cargo/release/cachyinstall"
    # every repository package the installer offers must exist (AUR ones can't be checked)
    "$installer" catalog check --no-config ||
        warn "the installer's catalog names packages the repositories don't have (above)"
fi

# Applies the overlay for flavour $1 to a fresh copy of upstream in $src.
prepare() {
    local flavour=$1 pkgs kernels name
    if [[ -e $src ]]; then
        # previous build leaves root-owned files behind
        sudo rm -rf --one-file-system "$src"
    fi
    mkdir -p "$src"
    git -C "$repo/upstream" archive HEAD | tar -x -C "$src"

    pkgs="$src/archiso/packages_desktop.x86_64"
    [[ -f $pkgs ]] || die "upstream layout changed: $pkgs not found"

    if [[ $flavour == minimal ]]; then
        while read -r name; do
            grep -qxF "$name" "$pkgs" || warn "overlay/minimal/packages.remove: '$name' is not in upstream's list"
        done < <(grep -vE '^[[:space:]]*(#|$)' "$repo/overlay/minimal/packages.remove")
        grep -vxFf <(grep -vE '^[[:space:]]*(#|$)' "$repo/overlay/minimal/packages.remove") \
            "$pkgs" > "$pkgs.new"
        mv "$pkgs.new" "$pkgs"
    fi

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

    if [[ $flavour == minimal ]]; then
        cat "$repo/overlay/minimal/customize_airootfs.sh" \
            >> "$src/archiso/airootfs/root/customize_airootfs.sh"
        cp -r "$repo/overlay/minimal/airootfs/." "$src/archiso/airootfs/"
        install -Dm755 "$installer" "$src/archiso/airootfs/usr/local/bin/cachyinstall"
        # mkarchiso resets modes it isn't told about
        sed -i '/^file_permissions=(/a \  ["/usr/local/bin/cachyinstall"]="0:0:755"' \
            "$src/archiso/profiledef.sh"
        grep -q '/usr/local/bin/cachyinstall' "$src/archiso/profiledef.sh" ||
            die "upstream layout changed: no file_permissions in profiledef.sh"
        echo "  removed $(grep -cvE '^[[:space:]]*(#|$)' "$repo/overlay/minimal/packages.remove") GUI packages; cachyinstall on tty1"
    fi
}

built=()
for flavour in "${flavours[@]}"; do
    msg "Preparing the $flavour flavour from upstream $rev"
    prepare "$flavour"

    msg "Building $flavour (upstream buildiso.sh -p desktop)"
    args=("$@")
    [[ ${KEEP_WORK:-0} == 1 ]] || args+=(-w)
    (cd "$src" && ./buildiso.sh -p desktop "${args[@]}")

    iso="$(find "$src/out/desktop" -maxdepth 1 -name '*.iso' -print -quit)"
    [[ -n $iso ]] || die "build finished but no ISO was produced"

    # upstream names it cachyos-desktop-linux-<date>
    name="$(basename "$iso" .iso)"
    name="${name/cachyos-desktop-/cachyos-$flavour-}-bcachefs"
    mkdir -p "$out"
    sudo mv "$iso" "$out/$name.iso"
    sudo mv "$src/out/desktop/"*.pkgs.txt "$out/$name.pkgs.txt" 2>/dev/null || true
    sudo chown "$USER:" "$out/$name".*
    (cd "$out" && sha256sum "$name.iso" > "$name.iso.sha256")
    {
        echo "upstream $rev"
        [[ $flavour != minimal ]] || echo "cachyinstall $(git -C "$repo/cachyinstall" rev-parse --short HEAD)"
    } > "$out/$name.upstream.txt"
    [[ ${KEEP_WORK:-0} == 1 ]] || sudo rm -rf --one-file-system "$src"
    built+=("$out/$name.iso")
done

msg "Done:"
printf '  %s\n' "${built[@]}"
