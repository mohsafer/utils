#!/usr/bin/env bash
# stalled-scan.sh - find (and optionally kill) hung processes, with logging
# Usage: stalled-scan.sh [-i secs] [-m rss_mb] [-a min_age] [-u user] [-p regex] [-x regex]
#                        [-k | -K | -n] [-g secs] [-l file] [-s] [-v]
#   -i  sampling interval in seconds (default 30)
#   -m  only flag idle processes holding >= this RSS in MB (default 200)
#   -a  ignore processes younger than this many seconds (default 300)
#   -u  only check this user's processes     -p  only names matching regex
#   -x  skip names matching regex (idle daemons)
#   -k  SIGTERM processes labelled STALLED   -K  same, then SIGKILL if still alive
#   -n  dry run: log what would be killed, kill nothing
#   -g  seconds to wait after SIGTERM before giving up / escalating (default 10)
#   -l  append events to this log file       -s  also send events to syslog/journal
#   -v  verbose terminal output (extra details, per-run summary)
set -u
umask 077     # log file readable only by the owner (cmdlines can contain secrets)

INTERVAL=30; MIN_RSS_MB=150; MIN_AGE=300; USER_F=""; INCLUDE=""
KILL=0; DRY=0; ESCALATE=0; GRACE=10; LOGFILE=""; SYSLOG=0; VERBOSE=0
EXCLUDE='^(systemd.*|sshd|dbus-daemon|NetworkManager|cron|agetty|Xorg|Xwayland|pipewire.*|wireplumber|gnome-shell|plasmashell|kwin.*)$'

while getopts "i:m:a:u:p:x:l:g:kKnsv" o; do
  case $o in
    i) INTERVAL=$OPTARG;; m) MIN_RSS_MB=$OPTARG;; a) MIN_AGE=$OPTARG;;
    u) USER_F=$OPTARG;;   p) INCLUDE=$OPTARG;;    x) EXCLUDE=$OPTARG;;
    l) LOGFILE=$OPTARG;;  g) GRACE=$OPTARG;;
    k) KILL=1;; K) KILL=1; ESCALATE=1;; n) KILL=1; DRY=1;;
    s) SYSLOG=1;; v) VERBOSE=1;;
    *) sed -n '2,15p' "$0"; exit 1;;
  esac
done

CLK=$(getconf CLK_TCK)
SELF=$$
FLAGGED=0; KILLED=0

# log LEVEL TERMINAL(0|1) message...
log() {
  local lvl=$1 term=$2; shift 2
  local line; line="$(date '+%F %T') [$lvl] $*"
  (( term )) && printf '%s\n' "$line"
  [[ -n $LOGFILE ]] && printf '%s\n' "$line" >>"$LOGFILE"
  (( SYSLOG )) && command -v logger >/dev/null && logger -t stalled-scan -p user.warning -- "[$lvl] $*"
  return 0
}

# prints: state cpu_ticks io_total starttime ppid
snap() {
  local pid=$1 stat rest io=0
  { stat=$(<"/proc/$pid/stat"); } 2>/dev/null || return 1
  rest=${stat##*) }
  local -a f; read -ra f <<<"$rest"
  (( ${#f[@]} >= 20 )) || return 1
  if [[ -r /proc/$pid/io ]]; then
    io=$(awk '{s+=$2} END{print s+0}' "/proc/$pid/io" 2>/dev/null)
  fi
  echo "${f[0]} $(( f[11] + f[12] )) ${io:-0} ${f[19]} ${f[1]}"
}

alive() {   # alive PID STARTTIME -> true if same process still running (not zombie)
  local s st st_start
  s=$(snap "$1") || return 1
  read -r st _ _ st_start _ <<<"$s"
  [[ $st_start == "$2" && $st != Z ]]
}

details() {
  local d=/proc/$1 exe cwd thr fds ks
  exe=$(readlink "$d/exe" 2>/dev/null); cwd=$(readlink "$d/cwd" 2>/dev/null)
  thr=$(awk '/^Threads/{print $2}' "$d/status" 2>/dev/null)
  fds=$(ls "$d/fd" 2>/dev/null | wc -l)
  ks=$(tr '\n' '|' 2>/dev/null <"$d/stack")
  echo "exe=${exe:--} cwd=${cwd:--} threads=${thr:--} fds=$fds kstack=${ks:--}"
}

# do_kill PID EXPECTED_SNAPSHOT COMM CONTEXT
do_kill() {
  local pid=$1 expect=$2 comm=$3 ctx=$4
  local e_st e_cpu e_io e_start n_st n_cpu n_io n_start now i rc
  read -r e_st e_cpu e_io e_start _ <<<"$expect"

  if (( DRY )); then
    log WOULD-KILL 1 "pid=$pid sig=TERM $ctx"; return
  fi

  # last-moment re-check: same process, still completely idle
  now=$(snap "$pid") || { log SKIP 1 "pid=$pid comm=$comm exited before kill"; return; }
  read -r n_st n_cpu n_io n_start _ <<<"$now"
  if [[ $n_start != "$e_start" || $n_cpu != "$e_cpu" || $n_io != "$e_io" ]]; then
    log SKIP 1 "pid=$pid comm=$comm became active again (or PID reused), not killing"; return
  fi

  kill -TERM "$pid" 2>/dev/null; rc=$?
  log KILL 1 "pid=$pid sig=TERM rc=$rc $ctx"
  if (( rc != 0 )); then
    log ERROR 1 "pid=$pid comm=$comm kill failed (rc=$rc, need root?)"; return
  fi

  for (( i=1; i<=GRACE; i++ )); do
    sleep 1
    if ! alive "$pid" "$e_start"; then
      log KILLED 1 "pid=$pid comm=$comm exited ${i}s after SIGTERM"
      KILLED=$(( KILLED + 1 )); return
    fi
  done

  if (( ESCALATE )); then
    kill -KILL "$pid" 2>/dev/null; rc=$?
    log KILL 1 "pid=$pid sig=KILL rc=$rc (still alive ${GRACE}s after SIGTERM)"
    sleep 2
    if alive "$pid" "$e_start"; then
      log ERROR 1 "pid=$pid comm=$comm still alive after SIGKILL (stuck in D state?)"
    else
      log KILLED 1 "pid=$pid comm=$comm exited after SIGKILL"
      KILLED=$(( KILLED + 1 ))
    fi
  else
    log WARN 1 "pid=$pid comm=$comm still alive ${GRACE}s after SIGTERM (use -K to escalate)"
  fi
}

# ---- first sample ----
declare -A B
for d in /proc/[0-9]*; do
  pid=${d#/proc/}
  (( pid == SELF || pid <= 2 )) && continue
  [[ -n $USER_F && $(stat -c %U "$d" 2>/dev/null) != "$USER_F" ]] && continue
  s=$(snap "$pid") || continue
  read -r _ _ _ _ ppid <<<"$s"
  [[ $ppid == 2 ]] && continue            # kernel thread
  B[$pid]=$s
done

sleep "$INTERVAL"

UP=$(cut -d' ' -f1 /proc/uptime)
printf '%-9s %7s %-2s %8s %7s %-16s %-22s %s\n' LABEL PID ST RSS AGE NAME WCHAN CMD

# ---- second sample and decisions ----
for pid in "${!B[@]}"; do
  a=$(snap "$pid") || continue
  read -r st1 cpu1 io1 start1 _ <<<"${B[$pid]}"
  read -r st2 cpu2 io2 start2 ppid2 <<<"$a"
  [[ $start1 == "$start2" ]] || continue  # PID reused

  { comm=$(<"/proc/$pid/comm"); } 2>/dev/null || continue
  [[ -n $INCLUDE && ! $comm =~ $INCLUDE ]] && continue
  [[ -n $EXCLUDE && $comm =~ $EXCLUDE ]] && continue

  rss=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$pid/status" 2>/dev/null); rss=${rss:-0}
  age=$(awk -v u="$UP" -v s="$start2" -v c="$CLK" 'BEGIN{print int(u - s/c)}')
  wchan=$(cat "/proc/$pid/wchan" 2>/dev/null); wchan=${wchan:--}
  fullcmd=$(tr '\0' ' ' 2>/dev/null <"/proc/$pid/cmdline" | cut -c1-300); fullcmd=${fullcmd% }

  label=""
  if [[ $st2 == Z ]]; then
    label=ZOMBIE
    fullcmd="(zombie) parent=$ppid2/$(cat "/proc/$ppid2/comm" 2>/dev/null)"
  elif [[ $st1 == D && $st2 == D && $cpu1 == "$cpu2" && $io1 == "$io2" ]]; then
    label=D-STUCK
  elif [[ $st2 == T ]] && (( rss >= MIN_RSS_MB )); then
    label=STOPPED
  elif [[ $st1 == "$st2" && $cpu1 == "$cpu2" && $io1 == "$io2" ]] \
       && (( rss >= MIN_RSS_MB && age >= MIN_AGE )); then
    label=STALLED
  fi
  [[ -z $label ]] && continue
  FLAGGED=$(( FLAGGED + 1 ))

  printf '%-9s %7s %-2s %6sMB %6ss %-16s %-22s %s\n' \
    "$label" "$pid" "$st2" "$rss" "$age" "${comm:0:16}" "${wchan:0:22}" "${fullcmd:0:70}"

  user=$(stat -c %U "/proc/$pid" 2>/dev/null)
  ctx="user=${user:-?} comm=$comm st=$st2 rss=${rss}MB age=${age}s wchan=$wchan ppid=$ppid2 cmd=\"$fullcmd\""
  log "FLAG-$label" 0 "pid=$pid $ctx"
  log DETAIL "$VERBOSE" "pid=$pid $(details "$pid")"

  if (( KILL )) && [[ $label == STALLED ]]; then
    do_kill "$pid" "$a" "$comm" "$ctx"
  elif (( KILL )) && [[ $label == D-STUCK ]]; then
    log SKIP 1 "pid=$pid comm=$comm is in D state, SIGTERM would have no effect; check disk/NFS/driver"
  fi
done

log INFO "$VERBOSE" "run done: scanned=${#B[@]} flagged=$FLAGGED killed=$KILLED interval=${INTERVAL}s"
