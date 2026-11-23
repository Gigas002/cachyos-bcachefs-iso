#!/usr/bin/env bash
# Runs inside the ISO root filesystem (arch-chroot) after all packages are
# installed, via mkarchiso's customize_airootfs.sh support.
# Added by cachyos-bcachefs-iso:
#   1. fail the build unless every kernel has a bcachefs module;
#   2. remove the build-only toolchain (headers, dkms, rust, clang/llvm),
#      keeping the already-built modules;
#   3. verify again.
set -euo pipefail

kernels=()
for kdir in /usr/lib/modules/*/; do
    [[ -e ${kdir}vmlinuz ]] && kernels+=("$(basename "$kdir")")
done
(( ${#kernels[@]} > 0 )) || { echo "bcachefs-iso: no kernels found" >&2; exit 1; }

verify() {
    local kver rc=0
    for kver in "${kernels[@]}"; do
        if mod=$(modinfo -k "$kver" -F filename bcachefs 2>/dev/null) && [[ -n $mod ]]; then
            echo "bcachefs-iso: $kver -> $mod ($(modinfo -k "$kver" -F version bcachefs 2>/dev/null || true))"
        else
            echo "bcachefs-iso: bcachefs module MISSING for kernel $kver" >&2
            rc=1
        fi
    done
    return "$rc"
}

# Known build breakages of the released bcachefs-dkms, fixed here and rebuilt
# for the affected kernels only. Each fix applies only where it's needed.
#
# inode_state helpers: bcachefs defines them for kernels < 6.19, but stable
# kernels got them backported (6.18.64 LTS), so they're defined twice. Drop
# bcachefs's copies for a kernel whose headers already have them.
fix_and_rebuild() {
    local kver src ver fsh
    src=$(find /usr/src -maxdepth 1 -name 'bcachefs-*' -print -quit)
    [[ -n $src ]] || return 0
    ver=${src##*/bcachefs-}
    fsh=$src/src/fs/bcachefs/vfs/fs.h
    for kver in "${kernels[@]}"; do
        modinfo -k "$kver" -F filename bcachefs &>/dev/null && continue
        if grep -q 'inode_state_set_raw' "/usr/lib/modules/$kver/build/include/linux/fs.h" 2>/dev/null &&
            grep -q '^static inline void inode_state_set_raw' "$fsh" 2>/dev/null; then
            echo "bcachefs-iso: $kver has the inode_state helpers, rebuilding without bcachefs's copies"
            cp "$fsh" "$fsh.orig"
            sed -i '/^#if LINUX_VERSION_CODE < KERNEL_VERSION(6,19,0)$/{N;/inode_state_read(struct inode \*inode)/s/^#if .*\n/#if 0\n/}' "$fsh"
            dkms install "bcachefs/$ver" -k "$kver" || true
            mv "$fsh.orig" "$fsh"
        fi
    done
}

fix_and_rebuild

echo "bcachefs-iso: verifying DKMS build"
verify

# Remove the toolchain. The DKMS remove hook would delete the built modules
# together with the headers, so mask it for this one transaction.
mapfile -t strip < <(pacman -Qq | grep -E '^(bcachefs-dkms|linux-cachyos[a-z0-9-]*-headers)$')
if (( ${#strip[@]} > 0 )); then
    echo "bcachefs-iso: removing build-only packages: ${strip[*]} (+ unneeded deps)"
    mkdir -p /etc/pacman.d/hooks
    ln -sf /dev/null /etc/pacman.d/hooks/71-dkms-remove.hook
    pacman -Rns --noconfirm "${strip[@]}"
    rm -f /etc/pacman.d/hooks/71-dkms-remove.hook
    rm -rf /var/lib/dkms
fi

for kver in "${kernels[@]}"; do depmod "$kver"; done

echo "bcachefs-iso: verifying after cleanup"
verify
