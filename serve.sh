#!/usr/bin/env bash
# serve-over-ssh.sh
#
# From your local machine this script:
#   1. SSHes to the server and starts `python3 -m http.server <port> --bind 127.0.0.1`
#      there, serving the home directory,
#   2. tunnels that port back to your machine,
#   3. opens http://localhost:<port> in your local browser once the tunnel answers.
#
# Usage:
#   ./serve-over-ssh.sh <server_ip_or_hostname> [port]
#   ./serve-over-ssh.sh <user@server>           [port]
#   ./serve-over-ssh.sh                # reads server.txt, or prompts for the IP
#
# With no argument the script looks for server.txt (in the current directory,
# then next to the script): one server per line, #comments and blank lines
# ignored. One entry → used directly; several → pick from a menu. No file →
# prompts for the IP, as before.
#
# The tunnel and the remote HTTP server both stop when you press Ctrl+C.
# If a stale http.server still holds the port on the server (e.g. left over
# from an earlier session), the script frees it before starting a fresh one.
# Default remote user: mosafer — change REMOTE_USER below if needed.

set -euo pipefail

REMOTE_USER="mosafer"

HOST_ARG="${1:-}"
PORT="${2:-8000}"
URL="http://localhost:${PORT}"

# --- which server to connect to ---------------------------------------------
# Order: explicit argument → server.txt (list of servers) → prompt for it.
if [[ -z "$HOST_ARG" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SERVER_FILE=""
  for candidate in "./server.txt" "$SCRIPT_DIR/server.txt"; do
    if [[ -f "$candidate" ]]; then SERVER_FILE="$candidate"; break; fi
  done

  SERVERS=()
  if [[ -n "$SERVER_FILE" ]]; then
    # one server per line; strip CR/spaces, drop #comments and blank lines
    while IFS= read -r sv; do
      SERVERS+=("$sv")
    done < <(sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' "$SERVER_FILE" | grep -v '^$')
  fi

  if [[ -n "$SERVER_FILE" && ${#SERVERS[@]} -eq 0 ]]; then
    echo "warning: $SERVER_FILE has no usable entries — asking instead" >&2
    SERVER_FILE=""
  fi

  if [[ -n "$SERVER_FILE" && ${#SERVERS[@]} -eq 1 ]]; then
    HOST_ARG="${SERVERS[0]}"
    echo "→ using server from $SERVER_FILE: $HOST_ARG"
  elif [[ -n "$SERVER_FILE" ]]; then
    echo "Servers from $SERVER_FILE:"
    i=1
    for sv in "${SERVERS[@]}"; do
      echo "  $i) $sv"
      i=$((i + 1))
    done
    while true; do
      read -rp "Pick a server [1-${#SERVERS[@]}], or type an IP: " choice
      if [[ -z "$choice" ]]; then
        continue
      elif [[ "$choice" =~ ^[0-9]+$ ]]; then
        if (( 10#$choice >= 1 && 10#$choice <= ${#SERVERS[@]} )); then
          HOST_ARG="${SERVERS[$((10#$choice - 1))]}"
          break
        fi
        echo "No such entry: $choice" >&2
      else
        HOST_ARG="$choice"        # typed a server that is not in the list
        break
      fi
    done
  else
    read -rp "Server IP or hostname: " HOST_ARG
  fi
fi
if [[ -z "$HOST_ARG" ]]; then
  echo "error: no server given" >&2
  exit 1
fi
if [[ "$HOST_ARG" == *@* ]]; then
  DEST="$HOST_ARG"
else
  DEST="${REMOTE_USER}@${HOST_ARG}"
fi

# --- make sure our local end of the tunnel is free --------------------------
if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then
  echo "error: local port ${PORT} is already in use — free it or pass another port" >&2
  exit 1
fi

tunnel_ok() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS -m 2 -o /dev/null "$URL" 2>/dev/null   # real HTTP check through the tunnel
  else
    (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null
  fi
}

# --- open the browser as soon as the tunnel starts answering ----------------
(
  up=0
  for _ in {1..60}; do                       # ~30 s
    if tunnel_ok; then up=1; break; fi
    sleep 0.5
  done

  if [[ "$up" == 1 ]]; then
    echo "→ tunnel is up, opening ${URL}"
    if command -v xdg-open >/dev/null 2>&1; then
      xdg-open "$URL" >/dev/null 2>&1 || true
    elif command -v open >/dev/null 2>&1; then          # macOS
      open "$URL"
    else
      echo "→ open ${URL} in your browser" >&2
    fi
  else
    echo "warning: nothing answered on ${URL} — check the ssh/python output above" >&2
  fi
) &
WATCHER_PID=$!
trap 'kill "$WATCHER_PID" 2>/dev/null || true' EXIT   # no orphaned watcher if ssh dies early

# --- what runs on the server -------------------------------------------------
# If a stale http.server (left over from an earlier session) still holds the
# port there, free it first; if something we cannot kill keeps the port, fail
# with instructions instead of a raw traceback.
REMOTE_CMD="
if command -v fuser >/dev/null 2>&1; then
  fuser -k ${PORT}/tcp >/dev/null 2>&1 || true
else
  for p in \$(ss -tlnp 2>/dev/null | grep ':${PORT} ' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do
    kill \$p 2>/dev/null || true
  done
fi
sleep 1
if ss -tln 2>/dev/null | grep -q ':${PORT} '; then
  echo 'ERROR: port ${PORT} is still in use on the server by a process we cannot kill (another user or a system service).' >&2
  echo 'Pick a different port, e.g.: ./serve-over-ssh.sh <server> 8080' >&2
  exit 1
fi
cd ~ && exec python3 -m http.server ${PORT} --bind 127.0.0.1
"

# --- tunnel + remote HTTP server (Ctrl+C stops both) ------------------------
echo "connecting to ${DEST} … (Ctrl+C to stop)"
ssh -o ExitOnForwardFailure=yes \
    -L "${PORT}:localhost:${PORT}" \
    "${DEST}" \
    "$REMOTE_CMD"
