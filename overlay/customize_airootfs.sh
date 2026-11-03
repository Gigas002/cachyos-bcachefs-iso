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
