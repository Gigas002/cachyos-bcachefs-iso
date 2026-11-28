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
# for the affected kernels only. Each fix applies only where its signature matches,
# and the source is restored after each build.
#
# inode_state helpers: bcachefs defines them for kernels < 6.19, but stable
# kernels got them backported (6.18.64 LTS), so they're defined twice. Drop
# bcachefs's copies for a kernel before 6.19 whose headers already have them.
#
# workqueue: kernel 7.3.6 renamed the Rust kernel::workqueue::system_unbound() to
# system_dfl(). Use the new name for a kernel whose Rust crate only has that.
fix_and_rebuild() {
    local kver src ver fsh aex rmeta major minor fixed
    src=$(find /usr/src -maxdepth 1 -name 'bcachefs-*' -print -quit)
    [[ -n $src ]] || return 0
    ver=${src##*/bcachefs-}
    fsh=$src/src/fs/bcachefs/vfs/fs.h
    aex=$src/src/fs/bcachefs/util/async_exec.rs
    for kver in "${kernels[@]}"; do
        modinfo -k "$kver" -F filename bcachefs &>/dev/null && continue
        IFS=. read -r major minor _ <<<"$kver"
        rmeta=/usr/lib/modules/$kver/build/rust/libkernel.rmeta
        fixed=()
        if (( major < 6 || (major == 6 && minor < 19) )) &&
            grep -q 'inode_state_set_raw' "/usr/lib/modules/$kver/build/include/linux/fs.h" 2>/dev/null &&
            grep -q '^static inline void inode_state_set_raw' "$fsh" 2>/dev/null; then
            cp "$fsh" "$fsh.orig"
            sed -i '/^#if LINUX_VERSION_CODE < KERNEL_VERSION(6,19,0)$/{N;/inode_state_read(struct inode \*inode)/s/^#if .*\n/#if 0\n/}' "$fsh"
            fixed+=("$fsh")
        fi
        if [[ -f $rmeta ]] && ! grep -qa 'system_unbound' "$rmeta" && grep -qa 'system_dfl' "$rmeta" &&
            grep -q 'kernel::workqueue::system_unbound()' "$aex" 2>/dev/null; then
            cp "$aex" "$aex.orig"
            sed -i 's/kernel::workqueue::system_unbound()/kernel::workqueue::system_dfl()/' "$aex"
            fixed+=("$aex")
        fi
        (( ${#fixed[@]} > 0 )) || continue
        echo "bcachefs-iso: $kver: rebuilding bcachefs with fixes in: ${fixed[*]##*/}"
        dkms install --force --no-depmod "bcachefs/$ver" -k "$kver" || true
        for f in "${fixed[@]}"; do mv "$f.orig" "$f"; done
        depmod "$kver"
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
