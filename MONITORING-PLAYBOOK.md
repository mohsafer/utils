# MONITORING-PLAYBOOK.md — Watchdogs, Sentinels & Progress Dashboards for long-running compute campaigns

**Purpose:** hand this file to an agent (or read it yourself) to build the full
monitoring + orchestration layer for ANY multi-phase, long-running project —
model training, evaluation sweeps, data pipelines, red-team campaigns, batch
jobs. **This file is self-contained:** §3, §4 and §5 embed COMPLETE, runnable
scripts (progress dashboard, watchdog/sentinel, resumable drivers). A new
project needs nothing else — copy them, edit the `<<<EDIT>>>`-marked blocks
(registry, live patterns, resource queries), and run. Origin: distilled from a
50+ GPU-hour research campaign whose four real incidents are catalogued in §6.

---

## 0. When to build this

You qualify if most of these are true:

- The work splits into **phases** with many **repeatable units** (cells, seeds,
  checkpoints, files, epochs, per-item jobs).
- Units take minutes-to-hours each; the whole campaign runs **days**.
- Execution is **serial on a scarce resource** (one GPU, one license, one queue).
- Interrupts happen (preemption, co-tenants, OOM killer, disk full, crashes).
- You (or an agent) need to answer *"where are we, what's running, what's left,
  when will it finish?"* **without reading raw logs**.

## 1. Architecture — three layers, one rule each

```
   DRIVERS  (do the work)          SENTINEL  (measure)         WATCHDOG  (respond)
   campaign_<phase>.sh             progress.sh                 watchdog.sh
   - resumable units               - one-shot or --watch       - telemetry every N min
   - lockfile-guarded              - weighted % + ETA          - tripwires -> ALERTS
   - chained via markers           - per-phase bars            - acts ONLY if gated
   - staged resource cycles        - live "NOW:" detection     - writes own logs only
        |                               |                           |
        └────────────── artifacts on disk are the single source of truth ──┘
```

**The one rule:** *the filesystem is the ledger.* A unit is "done" iff its
output artifact exists. Drivers check-then-skip; the dashboard counts
artifacts; the watchdog compares artifact freshness to process liveness. No
in-memory state, no separate progress DB, nothing to re-sync after a crash.


## 1.5 THE DASHBOARD INTERFACE CONTRACT (keep this output shape — it is the standard)

Later agents: **do not redesign the dashboard**. Every project's `progress.sh`
MUST produce the same graphical interface below, byte-for-byte in structure —
only the *registry entries*, *phase names*, and *live-detection patterns*
change. Reports then look identical across all projects and anyone who has
read one can read them all.

```
╔══════════════════════════════════════════════════════════════════╗
║ <PROJECT> campaign — <YYYY-MM-DD HH:MM UTC>
╚══════════════════════════════════════════════════════════════════╝
   [████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░]  38.2%          ← 44-char weighted bar
   weighted: ~951 min done · ~1536 min remain → ETA ≈ 25.6 h

  <phase-name>            [██████████████████] 100.0%  (n/N units, ~x/y min)
  <phase-name>            [████░░░░░░░░░░░░░░]  21.7%  (…)              ← 18-char per-phase bars
  …

  NOW: <one-line: the exact live process command>
       GPU [<used MiB, util %>] · disk <n>G free                       ← or the project's resource
       last: <one line from the newest phase log>

  REMAINS:
    · <phase>                a/N done, ~m min left                  ← only phases with work left
```

Hard rules of the contract:

1. **Glyphs:** `█` filled / `░` empty; main bar width 44, phase bars width 18.
2. **Weighted percent** uses *minutes* (unit count × minutes/unit), never raw
   unit counts — the bar must reflect real time, not item counts.
3. **Phases sorted** for stable output; `--watch` mode = `clear` + re-render
   every 60 s.
4. **`NOW:` block** shows the exact live worker command line, the resource
   state (GPU mem/util for ML projects; swap for CPU projects; queue depth for
   cluster jobs), and the newest log line — one glance = full situational
   awareness.
5. **REMAINS lists only phases with work left**, each with a minute estimate.
6. **Read-only guarantee** printed in the header comment of the script.
7. The registry (§3.1) is the ONLY section an agent edits, plus the live
   process patterns and the resource query command.

The complete runnable source is **§3.2 below** — copy it verbatim and edit
only the `<<<EDIT>>>` blocks.

---

## 2. Core principles (each one paid for in incident time — do not skip)

1. **Resumable by construction.** Every driver checks `output exists → skip`.
   Restarting the whole campaign must never redo finished work and must never
   corrupt it. Killing mid-unit costs at most that unit.
2. **Monitoring is READ-ONLY.** Dashboards/sentinels never write, never signal
   processes, never touch the GPU state. They only read artifact dirs, logs,
   `ps/pgrep`, `nvidia-smi`, `df`. A monitoring bug must be *incapable* of
   damaging the workload.
3. **Watchdogs alert by default; act only behind an explicit opt-in.** Any
   auto-kill/auto-relaunch is gated (env flag, default off). Relaunching a
   chain blindly caused a real duplication cascade — see §6.
4. **Lock every driver** (`mkdir /tmp/proj_<name>.lock` + `trap rmdir EXIT`).
   Two instances of the same driver = two writers racing the same artifacts.
5. **Chain phases with marker files** (`logs/DONE_<phase>`), *never* with
   `pgrep -f <script-name>` — see pitfall P1. Clear stale markers on resume.
6. **Wait on measurable resources, not names**: GPU-free = query memory <
   threshold; disk-free = `df`. Names can self-match; bytes can't.
7. **Staged resource cycles**: when inputs are huge (checkpoints, datasets),
   run `download → use → delete` one at a time and budget disk *before*
   launching. Peak, not total, is what kills you.
8. **Honest failure records.** A failed unit is recorded (`{error: ...}` in its
   output or an alert line), never silently retried or hidden.
9. **One-command pause & resume.** Kill by PID (verify with `ps`), write a
   pause-state doc, commit; resume = one script that rebuilds the chain.
10. **Append-only logs with one file per phase** (`logs/<date>_<phase>.log`),
    plus a session log `logs/<date>_<topic>.md` for the *why*.

## 3. Template A — `progress.sh` (dashboard: weighted bar + phases + ETA + NOW/REMAINS)

Usage after instantiation:

```bash
bash scripts/progress.sh          # one-shot report
bash scripts/progress.sh --watch  # live refresh every 60s
```

**How to adapt:** edit ONLY the `UNIT REGISTRY` block (§3.1). Everything else
is generic. A "unit" is any countable piece of work with a detectable
completion artifact.

### 3.1 The registry — the only project-specific part

```bash
# ─── UNIT REGISTRY (edit this) ────────────────────────────────────────────
# Format:  name|n_units|minutes_per_unit|done_check
#   done_check: a shell snippet that prints the NUMBER of completed units.
#   minutes: measured average if you have it; otherwise estimate, then
#   replace with measured values after the first few units land.

CELLS="
train/seed0|1|45|[ -f runs/seed0/model.sfinal ] && echo 1 || echo 0
train/seed1|1|45|[ -f runs/seed1/model.sfinal ] && echo 1 || echo 0
train/seed2|1|45|[ -f runs/seed2/model.sfinal ] && echo 1 || echo 0
eval/suite_v1|3|20|ls eval_results/seed*/scores.json 2>/dev/null | wc -l
quantize/int8|1|30|[ -f runs/int8/metrics.json ] && echo 1 || echo 0
phase_data/cleanup|1|15|[ -f .done_data_cleanup ] && echo 1 || echo 0
"
# Non-filesystem-counted units (e.g. N small files per unit) go in a second
# table:  phase|n_units|min_per_unit|count_snippet
COUNTED="
redteam/prompt-arms|60|8|ls attacks/arms/*.json 2>/dev/null | wc -l
grader/pass|1|150|[ -f grades/final.json ] && echo 1 || echo 0
"
# ──────────────────────────────────────────────────────────────────────────
```

### 3.2 Full script (complete, runnable — copy verbatim)

```bash
#!/bin/bash
# progress.sh — READ-ONLY dashboard: never writes files, never signals
# processes, never touches GPU state. Safe against any live workload.
# Usage:  bash scripts/progress.sh          # one-shot report
#         bash scripts/progress.sh --watch  # live refresh every 60s
set -u
cd "$(dirname "$0")/.." || exit 1            # project root = parent of scripts/

# ══════════════ <<<EDIT>>> PROJECT-SPECIFIC BLOCK (the only part you change) ══
RES=results                                   # where unit artifacts land
PHASE_ORDER=(                                 # stable phase display order
  "data" "train" "eval" "quantize" "redteam" "grader" "reports"
)
# live-process patterns (regex for pgrep -f) — what "working" looks like here:
LIVE_PAT="python.*(train|eval|run_|attack|grade)"
# resource query: GPU for ML; else swap/queue equivalents
resource_line() { nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader 2>/dev/null | paste -sd' '; }
# unit registry:  name|n_units|minutes_per_unit|done_check (prints completed n)
CELLS="
data/download|1|30|[ -f data/dataset.locked ] && echo 1 || echo 0
train/seed0|1|45|[ -f runs/seed0/model.sfinal ] && echo 1 || echo 0
train/seed1|1|45|[ -f runs/seed1/model.sfinal ] && echo 1 || echo 0
train/seed2|1|45|[ -f runs/seed2/model.sfinal ] && echo 1 || echo 0
eval/suite|3|20|ls eval_results/seed*/scores.json 2>/dev/null | wc -l
quantize/int8|1|30|[ -f runs/int8/metrics.json ] && echo 1 || echo 0
redteam/arms|60|8|ls attacks/arms/*.json 2>/dev/null | wc -l
grader/pass|1|150|find grades -name '*.json' -newermt '2026-01-01' 2>/dev/null | grep -q . && echo 1 || echo 0
"
# ══════════════ END EDIT BLOCK ════════════════════════════════════════════════

# ---- counting ---------------------------------------------------------------
declare -A PH_D PH_T PH_MIND PH_MINT
TDONE=0; TALL=0
while IFS='|' read -r name units mins check; do
  [ -z "$name" ] && continue
  ph="${name%%/*}"                           # phase = prefix before the slash
  done_n=$(bash -c "$check" 2>/dev/null || echo 0)
  done_n=${done_n%%.*}; done_n=$(( done_n > units ? units : done_n ))
  PH_T[$ph]=$(( ${PH_T[$ph]:-0} + units ))
  PH_D[$ph]=$(( ${PH_D[$ph]:-0} + done_n ))
  PH_MINT[$ph]=$(( ${PH_MINT[$ph]:-0} + units * mins ))
  PH_MIND[$ph]=$(( ${PH_MIND[$ph]:-0} + done_n * mins ))
  TDONE=$(( TDONE + done_n * mins )); TALL=$(( TALL + units * mins ))
done <<< "$CELLS"

# ---- render helpers -----------------------------------------------------------
bar() { local d=$1 t=$2 w=${3:-22} f; [ "$t" -eq 0 ] && t=1
        f=$(( w * d / t )); [ $f -gt $w ] && f=$w
        for ((i=0;i<f;i++)); do printf '█'; done
        for ((i=f;i<w;i++)); do printf '░'; done; }
pct() { awk -v d="$1" -v t="$2" 'BEGIN{ if(t==0){print "0.0"} else printf "%.1f", 100*d/t }'; }

# ---- live activity ------------------------------------------------------------
worker=$(pgrep -af "$LIVE_PAT" 2>/dev/null | grep -v "bash -c" | head -1 | cut -c1-140)
res=$(resource_line)
dfree=$(df --output=avail -BG . | tail -1 | tr -dc '0-9')
newest_log=$(ls -t logs/*.log 2>/dev/null | head -1)
last_line=$([ -n "$newest_log" ] && grep -v "^Loading" "$newest_log" 2>/dev/null | tail -1 | cut -c1-120)

# ---- report (interface contract §1.5 — do not change the shape) ----------------
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║ <PROJECT> campaign — $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "╚══════════════════════════════════════════════════════════════════╝"
printf '   ['
bar "$TDONE" "$TALL" 44
printf ']  %s%%\n' "$(pct "$TDONE" "$TALL")"
printf '   weighted: ~%s min done · ~%s min remain → ETA ≈ %s h\n\n' \
  "$TDONE" "$(( TALL - TDONE ))" "$(awk -v m="$(( TALL - TDONE ))" 'BEGIN{printf "%.1f", m/60}')"

for ph in "${PHASE_ORDER[@]}"; do
  t=${PH_T[$ph]:-0}; [ "$t" -eq 0 ] && continue
  d=${PH_D[$ph]:-0}
  printf '  %-24s [%b] %5s%%  (%s/%s units, ~%s/%s min)\n' "$ph" \
    "$(bar "$d" "$t" 18)" "$(pct "${PH_MIND[$ph]:-0}" "${PH_MINT[$ph]:-0}")" \
    "$d" "$t" "${PH_MIND[$ph]:-0}" "${PH_MINT[$ph]:-0}"
done

echo
echo "  NOW: ${worker:-<no worker — pipeline idle>}"
echo "       resource [$res] · disk ${dfree}G free"
echo "       last: $last_line"
echo
echo "  REMAINS:"
for ph in "${PHASE_ORDER[@]}"; do
  rm_m=$(( ${PH_MINT[$ph]:-0} - ${PH_MIND[$ph]:-0} ))
  [ "$rm_m" -gt 0 ] && printf '    · %-24s %s/%s done, ~%s min left\n' \
      "$ph" "${PH_D[$ph]:-0}" "${PH_T[$ph]:-0}" "$rm_m"
done

if [ "$TAG" = "--watch" ]; then while true; do sleep 60; clear; "$0"; done; fi
```

> Pseudo-code of the flow, for agents porting it to other languages:
> ```
> registry = [ (name, units, minutes, done_check) ]        # the only edit block
> for each unit:  done_n = run(done_check); accumulate per phase + weighted totals
> pct = 100 * done_minutes / total_minutes
> render: box header → 44-char main bar + ETA → per-phase 18-char bars (sorted)
>         → NOW (live process via pgrep -f LIVE_PAT, resource query, newest log line)
>         → REMAINS (only phases with minutes left)
> if --watch: clear + recurse every 60s
> ```

### 3.3 Dashboard design notes

- **Weight by minutes, not by unit count** — a 30-min 9B cell and a 12-min 1.7B
  cell must not count equally, or the bar lies.
- **Replace estimates with measurements** as units land; the ETA sharpens itself.
- The `NOW:` line is the most-used output: newest live process + GPU + last
  log line tell you everything in one glance.
- Keep phase names short (they label bars).

## 4. Template B — `watchdog.sh` (complete, runnable — copy verbatim)

Sentinel telemetry + tripwires. **Read-only except its own two log files.**
Never kills, deletes, or relaunches unless `ENABLE_ACTIONS=1` is explicitly set.

```bash
#!/bin/bash
# watchdog.sh — sentinel + tripwires for a long-running compute campaign.
# Usage:  nohup bash scripts/watchdog.sh > /dev/null 2>&1 &   # daemon, 5-min cadence
#         bash scripts/watchdog.sh --once                     # one-shot status
set -u
cd "$(dirname "$0")/.." || exit 1

# ══ <<<EDIT>>> project-specific block ════════════════════════════════════════
WL=logs/watchdog.log                    # telemetry (append-only)
AL=logs/sentinel-alerts.log             # alerts only
WATCH_DIRS="results runs logs"          # dirs whose newest mtime = "progress"
LIVE_PAT="python.*(train|eval|run_|attack|grade)"   # what a live worker looks like
LOCK_PREFIX="/tmp/proj_"                # drivers hold /tmp/proj_<phase>.lock
RESUME_SCRIPT="scripts/resume_campaign.sh"
# resource query: GPU for ML; swap "used MiB" for any held-resource metric
resource_mem() { nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | tr -dc '0-9'; }
MEM_HELD_LIMIT=2000                     # MiB held with zero workers => foreign/orphan
STALE_DEAD=1200                         # s silence + no processes = dead pipeline
STUCK=2700                              # s silence WITH a worker = stuck (alert only)
DISK_MIN_GB=6                           # keep above the next staged step's PEAK
CHECK_EVERY=300
ENABLE_ACTIONS=${ENABLE_ACTIONS:-0}     # gate ALL actions; default = alert-only
# ══ END EDIT ═════════════════════════════════════════════════════════════════

ts() { date -u +%FT%TZ; }
now() { date +%s; }
# P4: the \n in printf is load-bearing — without it all mtimes concatenate and
# staleness silently reads the FIRST file walked instead of the newest.
newest_age() { local n; n=$(find $WATCH_DIRS -type f -printf '%T@\n' 2>/dev/null \
                            | sort -rn | head -1); n=${n%%.*}
               echo $(( $(now) - ${n:-$(now)} )); }
workers()     { pgrep -f "$LIVE_PAT" 2>/dev/null | wc -l; }
locks_held()  { ls "$LOCK_PREFIX"*.lock 2>/dev/null | wc -l; }
alert()       { echo "[$(ts)] $*" >> "$AL"; }

dead_pipeline() { [ "$(workers)" -eq 0 ] && [ "$(locks_held)" -eq 0 ] \
                  && [ "$(newest_age)" -gt "$STALE_DEAD" ]; }

check() {
  local w=$(workers) lk=$(locks_held) age=$(newest_age) mem=$(resource_mem)
  local dfree=$(df --output=avail -BG . | tail -1 | tr -dc '0-9')
  echo "[$(ts)] workers=$w locks=$lk stale=${age}s mem=[${mem:-n/a}MiB] disk=${dfree}G" >> "$WL"

  # tripwire 1 — dead pipeline (crash, OOM-kill, silent termination)
  if dead_pipeline; then
    if [ "$ENABLE_ACTIONS" = "1" ]; then
      alert "dead pipeline (stale ${age}s) -> auto-resume $RESUME_SCRIPT"
      nohup bash "$RESUME_SCRIPT" >> "$WL" 2>&1 &
    else
      alert "DEAD PIPELINE: stale ${age}s, nothing running — resume manually: bash $RESUME_SCRIPT"
    fi
  fi
  # tripwire 2 — stuck (a slow phase is not a dead one; a human decides)
  if [ "$w" -gt 0 ] && [ "$age" -gt "$STUCK" ]; then
    alert "STUCK: worker alive but no progress ${age}s — inspect; restart by PID if confirmed"
  fi
  # tripwire 3 — disk (fire BEFORE staged download cycles hit ENOSPC)
  if [ "$dfree" -lt "$DISK_MIN_GB" ]; then
    alert "DISK CRITICAL ${dfree}G < ${DISK_MIN_GB}G — free space before the next staged step"
  fi
  # tripwire 4 — foreign resource (GPU held by a co-tenant or orphan)
  if [ "$w" -eq 0 ] && [ "${mem:-0}" -gt "$MEM_HELD_LIMIT" ]; then
    alert "FOREIGN RESOURCE: ${mem}MiB held with no campaign worker"
  fi
}

if [ "${1:-}" = "--once" ]; then check; tail -n 5 "$AL" 2>/dev/null; exit 0; fi
echo "[$(ts)] watchdog started (pid $$, every ${CHECK_EVERY}s, actions=$ENABLE_ACTIONS)" >> "$WL"
while true; do check; sleep "$CHECK_EVERY"; done
```

Telemetry line format (one per check, append-only):
`[ts] workers=N locks=N stale=Ns mem=[MiB] disk=NG`

Tripwire semantics: **dead pipeline** (auto-resume if gated, else loud alert),
**stuck** (alert only — a slow phase is not a dead one; a human decides),
**disk** (alert before staged cycles hit ENOSPC), **foreign resource** (GPU
held by something that isn't yours).

## 5. Template C — drivers + resume (complete, runnable — copy verbatim)

One driver per phase. Rules baked in: **lockfile dedupe, predecessor-marker
wait, resource-level wait, resumable units, staged cycles, honest failures,
DONE marker.**

```bash
#!/bin/bash
# campaign_<phase>.sh — one phase of the chain.
set -u
cd "$(dirname "$0")/.." || exit 1

PHASE=<phase>                                   # <<<EDIT>>>
LOG=logs/$(date +%Y-%m-%d)_$PHASE.log
LOCK=/tmp/proj_$PHASE.lock
[ -d "$LOCK" ] && { echo "[$(date -u +%FT%TZ)] already running" >> "$LOG"; exit 0; }
mkdir "$LOCK"; trap 'rmdir "$LOCK" 2>/dev/null' EXIT
say()    { echo "[$(date -u +%FT%TZ) $PHASE] $*" >> "$LOG"; }
dfline() { df -h . | tail -1 >> "$LOG"; }

# ---- waits: predecessor marker + free resource (NEVER pgrep names — pitfall P1)
while [ ! -f logs/DONE_<prev_phase> ]; do sleep 60; done
while [ "$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | tr -dc '0-9')" -gt 2000 ]; do sleep 120; done
sleep 20                                          # let the predecessor exit cleanly

# ---- resumable unit runner: skip iff the artifact exists (the ledger rule)
run_unit() {  # run_unit <artifact-path> <description> <command...>
  local art=$1 desc=$2; shift 2
  if [ -e "$art" ]; then say "skip $desc (done)"; return 0; fi
  say "start $desc"; dfline
  "$@" >> "$LOG" 2>&1; local rc=$?
  say "rc=$rc for $desc"; dfline
  [ $rc -ne 0 ] && say "HONEST FAILURE recorded for $desc (never silently retried)"
  return $rc
}

# ---- staged-cycle helpers for oversized inputs (pitfall P3): ONE at a time
fetch()   { say "fetch $1"; <download command for $1> >> "$LOG" 2>&1; }   # <<<EDIT>>>
release() { say "release $1"; rm -rf <staging-path-for-$1> 2>/dev/null; dfline; }

# ---- the phase's work (EDIT list) ────────────────────────────────────────────
run_unit runs/seed0/model.sfinal "train seed0" python train.py --seed 0
run_unit runs/seed1/model.sfinal "train seed1" python train.py --seed 1
run_unit runs/seed2/model.sfinal "train seed2" python train.py --seed 2
run_unit eval_results/summary.json "eval suite" python eval.py --all-seeds

# staged example (an input too big to hold alongside everything else):
#   fetch big_input_A && run_unit results/A.json python work.py A
#   release big_input_A                       # free BEFORE fetching B
#   fetch big_input_B && run_unit results/B.json python work.py B
#   release big_input_B

touch logs/DONE_$PHASE
say "DONE"
```

```bash
#!/bin/bash
# resume_campaign.sh — ONE command to (re)start the entire chain. Idempotent:
# finished units are skipped; a crash never costs more than the unit in flight.
set -u
cd "$(dirname "$0")/.."
rm -f logs/DONE_*                            # markers rebuilt as phases finish
for ph in <phase1> <phase2> <phase3>; do     # <<<EDIT>>> chain order
  nohup bash scripts/campaign_$ph.sh >> logs/$(date +%Y-%m-%d)_chain.log 2>&1 &
  sleep 2
done
echo "chain resumed — bash scripts/progress.sh | tail -f logs/$(date +%Y-%m-%d)_*.log"
```

**Pause protocol** (the mirror image, for co-tenanted machines):

1. List, then kill by PID — never `pkill -f <name>` (pitfall P1):
   `ps aux | grep -E "<driver|worker patterns>" | grep -v grep` → `kill <pids>`.
2. Decide each orphaned child: let it finish (useful) or kill it (write race).
3. Verify: no processes, resource freed (`nvidia-smi` = 0), `df` headroom.
4. Write a pause-state doc (`logs/<date>_pause-state.md`): what completed,
   what was in flight, the exact resume command.
5. Commit everything (`git add -A && git commit`). Resume later = one command.

## 6. Pitfalls (all encountered in practice)

- **P1 — self-matching patterns.** `pkill -f myscript.sh` inside a wrapper whose
  cmdline contains that string kills *itself* first; `pgrep -f name` in a
  driver's wait-loop matches an *agent's monitoring command* mentioning the
  name → the driver waits forever. Fix: kill by PID (list with `ps`, verify),
  wait on markers/resource levels, never on names.
- **P2 — orphan children.** Killing a driver bash does NOT kill its running
  python child (it orphans and keeps writing). Always `ps` after kills; the
  orphan may be *useful* (let a long unit finish) or harmful (write race) —
  decide explicitly, then verify.
- **P3 — ENOSPC mid-campaign.** A download that fails at 99% leaves giant
  partial temp files; `du` the cache dirs, budget the PEAK (bf16+fp32
  conversions!), and keep a staged cycle. Alert at a threshold ABOVE what the
  next staged step needs.
- **P4 — false staleness.** `find -printf '%T@'` without `\n` concatenates all
  timestamps into one line → "newest artifact" becomes the first file walked
  → phantom stuck-alerts. Always `%T@\n`.
- **P5 — stored artifacts masquerading as progress.** If a repo ships old
  results (grader outputs, judge grades), a file-existence check counts them
  as YOUR progress. Detect *fresh* artifacts (mtime newer than campaign start)
  or write your own markers.
- **P6 — duplicate-instance cascades.** Relaunching a chain while old driver
  instances are still waiting → two writers per artifact. Locks (§5) make the
  second instance exit; prefer locks over "be careful".
- **P7 — tooling phones home.** Model/dataset loaders may 401 on gated repos
  even when the artifact is fully cached (and some offline modes don't follow
  symlinked caches). Test the offline path early; point the cache env var at
  the real location; download once, audit, delete (staged).
- **P8 — in-place edits of running scripts.** Bash reads scripts lazily;
  editing a driver that is mid-execution corrupts the remaining lines. Patch
  a *copy* and swap, or wait for the phase boundary.

## 7. Adaptation checklist (run this in a new project)

1. List the phases; give each a driver script with lock + marker + resume-skip.
2. Enumerate units; assign `minutes` (measure ASAP) and a `done_check` glob.
3. Instantiate `progress.sh` (edit only the registry + live-process patterns)
   **preserving the §1.5 interface contract exactly** — same glyphs, bar widths,
   blocks, and `--watch` behavior, so every project's report reads identically.
4. Instantiate `watchdog.sh`; set thresholds (stale, stuck, disk); start it
   with `nohup` and confirm one instance: `pgrep -f watchdog.sh | wc -l`.
5. Define the resource budget (disk peak per staged cycle; GPU memory envelope
   per co-tenant) and put alerts above the danger line.
6. Write `resume_campaign.sh` (clear markers → launch chain) and a **pause
   protocol**: kill by PID → `ps` verify → pause-state doc → commit.
7. Log conventions: `logs/<date>_<phase>.log` per driver (append-only),
   `logs/<date>_<session>.md` for decisions; alerts separated from telemetry.
8. Dry-run the failure modes once: kill a driver mid-unit, fill the disk
   threshold, run two instances — confirm every tripwire fires and nothing
   corrupts.

## 8. The guarantee to preserve

> Monitoring reads; drivers write; the filesystem decides. Every destructive
> or chain-restarting action sits behind an explicit opt-in. Every failure is
> recorded, never hidden. Pause and resume are one command each, and a crash
> never costs more than the unit in flight.

— Adapted from a 50+ GPU-hour GPU research campaign (Nov 2026): 4 real
incidents (OOM kill, duplicate cascade, ENOSPC starvation, gated-repo 401),
zero data loss, all diagnosed from telemetry.
