#!/usr/bin/env bash
# disable-akonadi.sh - completely disable Akonadi for the current user (Debian KDE)
#
# Usage:
#   ./disable-akonadi.sh            disable Akonadi
#   ./disable-akonadi.sh --baloo    disable Akonadi and the Baloo file indexer
#   ./disable-akonadi.sh --undo     revert everything this script did
#
# Run as your normal user, not root.

set -u

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as your normal user, not root." >&2
    exit 1
fi

DO_BALOO=0
UNDO=0
for arg in "$@"; do
    case "$arg" in
        --baloo) DO_BALOO=1 ;;
        --undo)  UNDO=1 ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}"
SERVERRC="$CONF_DIR/akonadi/akonadiserverrc"
DBUS_DIR="$DATA_DIR/dbus-1/services"
DBUS_FILE="$DBUS_DIR/org.freedesktop.Akonadi.Control.service"
AUTOSTART_USER="$CONF_DIR/autostart"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

stop_akonadi() {
    if command -v akonadictl >/dev/null 2>&1; then
        akonadictl stop 2>/dev/null || true
    fi
    sleep 2
    pkill -u "$USER" -f 'akonadi' 2>/dev/null || true
}

akonadi_units() {
    systemctl --user list-unit-files --no-legend 'akonadi*' 2>/dev/null | awk '{print $1}'
}

# ---------------------------------------------------------------- UNDO
if [ "$UNDO" -eq 1 ]; then
    log "Reverting changes"

    if [ -f "$SERVERRC" ]; then
        sed -i 's/^StartServer=false/StartServer=true/' "$SERVERRC"
        echo "StartServer set to true in $SERVERRC"
    fi

    rm -f "$DBUS_FILE" && echo "Removed $DBUS_FILE"

    for f in /etc/xdg/autostart/*akonadi*.desktop; do
        [ -e "$f" ] || continue
        rm -f "$AUTOSTART_USER/$(basename "$f")" && echo "Removed override for $(basename "$f")"
    done

    for u in $(akonadi_units); do
        systemctl --user unmask "$u" 2>/dev/null && echo "Unmasked $u"
    done

    echo
    echo "Done. Log out and back in, or run: akonadictl start"
    exit 0
fi

# ---------------------------------------------------------------- 1. stop
log "1/5 Stopping Akonadi"
stop_akonadi

# ---------------------------------------------------------------- 2. config
log "2/5 Setting StartServer=false in $SERVERRC"
mkdir -p "$(dirname "$SERVERRC")"
if [ ! -f "$SERVERRC" ]; then
    printf '[%%General]\nStartServer=false\n' > "$SERVERRC"
elif grep -q '^StartServer=' "$SERVERRC"; then
    sed -i 's/^StartServer=.*/StartServer=false/' "$SERVERRC"
elif grep -q '^\[%General\]' "$SERVERRC"; then
    sed -i '/^\[%General\]/a StartServer=false' "$SERVERRC"
else
    printf '\n[%%General]\nStartServer=false\n' >> "$SERVERRC"
fi
grep -n 'StartServer' "$SERVERRC"

# ---------------------------------------------------------------- 3. dbus
log "3/5 Overriding the D-Bus activation file"
mkdir -p "$DBUS_DIR"
cat > "$DBUS_FILE" <<'EOF'
[D-BUS Service]
Name=org.freedesktop.Akonadi.Control
Exec=/bin/false
EOF
echo "Wrote $DBUS_FILE"

# ---------------------------------------------------------------- 4. autostart + systemd
log "4/5 Hiding autostart entries and masking systemd user units"
mkdir -p "$AUTOSTART_USER"
found=0
for f in /etc/xdg/autostart/*akonadi*.desktop; do
    [ -e "$f" ] || continue
    found=1
    target="$AUTOSTART_USER/$(basename "$f")"
    cp -f "$f" "$target"
    sed -i '/^Hidden=/d' "$target"
    echo "Hidden=true" >> "$target"
    echo "Hidden: $(basename "$f")"
done
[ "$found" -eq 0 ] && echo "No Akonadi autostart entries found in /etc/xdg/autostart"

units="$(akonadi_units)"
if [ -n "$units" ]; then
    for u in $units; do
        systemctl --user stop "$u" 2>/dev/null || true
        systemctl --user mask "$u" 2>/dev/null && echo "Masked $u"
    done
else
    echo "No Akonadi systemd user units found"
fi

# ---------------------------------------------------------------- optional baloo
if [ "$DO_BALOO" -eq 1 ]; then
    log "Disabling Baloo file indexer"
    if command -v balooctl6 >/dev/null 2>&1; then
        balooctl6 disable
    elif command -v balooctl >/dev/null 2>&1; then
        balooctl disable
    else
        echo "balooctl not found, skipping"
    fi
fi

# ---------------------------------------------------------------- 5. verify
log "5/5 Verifying"
stop_akonadi
if pgrep -u "$USER" -a akonadi >/dev/null 2>&1; then
    echo "Some Akonadi processes are still running (they should be gone after re-login):"
    pgrep -u "$USER" -a akonadi
else
    echo "No Akonadi processes running."
fi

echo
echo "Done. Log out and back in to make sure nothing relaunches it."
echo "To revert: $0 --undo"
