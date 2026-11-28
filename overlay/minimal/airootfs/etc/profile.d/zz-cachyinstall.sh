# Starts cachyinstall once, for the live user's login on the first console.
# Added by cachyos-bcachefs-iso (minimal flavour).
if [ "$(id -un)" = liveuser ] && [ "$(tty)" = /dev/tty1 ] && [ -n "${XDG_RUNTIME_DIR:-}" ] &&
    [ ! -e "$XDG_RUNTIME_DIR/cachyinstall-started" ]; then
    : > "$XDG_RUNTIME_DIR/cachyinstall-started"
    sudo cachyinstall
    echo
    echo "cachyinstall has exited. Start it again with: sudo cachyinstall"
    echo "(sudo cachyinstall --demo looks around without changing anything; nmtui connects to Wi-Fi)"
fi
