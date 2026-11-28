
# --- minimal flavour (appended by build.sh) ---
# Console only: boot to multi-user.target, no display manager. The live user is
# still logged in on tty1, where /etc/profile.d/zz-cachyinstall.sh starts the installer.
echo "bcachefs-iso: minimal flavour: console only"
rm -f /etc/systemd/system/display-manager.service
ln -sf /usr/lib/systemd/system/multi-user.target /etc/systemd/system/default.target
command -v cachyinstall >/dev/null || { echo "bcachefs-iso: cachyinstall missing" >&2; exit 1; }
