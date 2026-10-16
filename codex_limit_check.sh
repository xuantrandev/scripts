#!/usr/bin/env bash
#
# codex_limit_check.sh — detect a frozen Codex 5h limit window and kick it
# with a cheap-model request so the countdown resumes.
#
# Requires: Bash 4+, codex CLI (logged in), jq, python3.
# Install codex first: npm i -g @openai/codex  (then `codex login`)
#
# How it works:
#   1. Reads rate limits via `codex app-server` JSON-RPC
#      (method account/rateLimits/read, same data /status shows).
#   2. Takes two snapshots WAIT seconds apart and looks at the 5h window.
#      A healthy window always carries a resetsAt timestamp (the window
#      expiry, which is SUPPOSED to stay identical between polls — so an
#      unchanged resetsAt is normal and never triggers a kick).
#   3. Only when the 5h window shows NO reset time in BOTH snapshots
#      (countdown never scheduled), or a reset >= 5h away in BOTH snapshots
#      (a live 5h window can never show that — countdown stuck, even at 0%),
#      does it send one minimal `codex exec --model <cheap>` request ("ping")
#      to open/touch the window and trigger the countdown.
#      A reset under 5h away (even at 100% used) means "wait for reset",
#      never a kick — kicking a genuinely exhausted quota only burns more.
#
# One-shot design: run it from cron every ~5 minutes.
set -euo pipefail

MODEL="gpt-6-luna"
WAIT=10
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/codex_limit_check"
EXEC_PROMPT="ping"
DRY_RUN=false
NO_KICK=false
VERBOSE=false
TIMEOUT_SECS=30
CODEX_BIN="${CODEX_BIN:-codex}"

usage() {
    cat <<'EOF'
Usage: codex_limit_check.sh [options]

Check the Codex 5-hour limit window. If the window reports usage but no
reset time (countdown never scheduled), or a reset >= 5h away (countdown
stuck — a live 5h window always resets within 5h), send one cheap-model
request to trigger the countdown. A reset under 5h away never triggers
a kick.

Options:
  --model NAME        Cheap model for the kick request (default: gpt-5-mini)
  --wait SECS         Seconds between the two limit snapshots (default: 30)
  --state-dir DIR     State/log directory (default: ~/.cache/codex_limit_check)
  --exec-prompt TEXT  Prompt sent for the kick (default: ping)
  --dry-run           Detect and report only, never run `codex exec`
  --no-kick           Same as --dry-run (detect only)
  --timeout SECS      app-server RPC timeout per snapshot (default: 30)
  --verbose           Print extra diagnostics to stderr
  --help              Show this help and exit

Exit codes: 0 ok (or kick sent ok), 1 runtime/kick failure, 2 usage/env error.

Cron example (every 5 minutes):
  */5 * * * * /path/to/codex_limit_check.sh --wait 150 >> ~/.cache/codex_limit_check/cron.log 2>&1

Requires: codex (npm i -g @openai/codex, then `codex login`), jq, python3.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
die_usage() { printf 'Error: %s\n' "$*" >&2; exit 2; }
vlog() { [[ $VERBOSE == true ]] || return 0; printf '%s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
    case $1 in
        --model) MODEL=${2:?--model needs a value}; shift 2 ;;
        --wait) WAIT=${2:?--wait needs a value}; shift 2 ;;
        --state-dir) STATE_DIR=${2:?--state-dir needs a value}; shift 2 ;;
        --exec-prompt) EXEC_PROMPT=${2:?--exec-prompt needs a value}; shift 2 ;;
        --timeout) TIMEOUT_SECS=${2:?--timeout needs a value}; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --no-kick) NO_KICK=true; shift ;;
        --verbose) VERBOSE=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die_usage "unknown argument: $1 (see --help)" ;;
    esac
done

[[ $WAIT =~ ^[0-9]+$ ]] || die_usage "--wait must be a non-negative integer"
[[ $TIMEOUT_SECS =~ ^[0-9]+$ && $TIMEOUT_SECS -gt 0 ]] || die_usage "--timeout must be a positive integer"
[[ -n $MODEL ]] || die_usage "--model must not be empty"

command -v "$CODEX_BIN" >/dev/null 2>&1 \
    || die_usage "codex CLI not found (CODEX_BIN=$CODEX_BIN). Install it first: npm i -g @openai/codex"
command -v jq >/dev/null 2>&1 || die_usage "jq not found; install jq"
command -v python3 >/dev/null 2>&1 || die_usage "python3 not found; install python3"

mkdir -p "$STATE_DIR" || die_usage "cannot create state dir $STATE_DIR"
HISTORY_LOG="$STATE_DIR/history.log"

# fetch_ratelimits_raw: print the raw JSON-RPC response envelope for
# account/rateLimits/read (the line with "id": 2) to stdout.
fetch_ratelimits_raw() {
    CODEX_BIN="$CODEX_BIN" RPC_TIMEOUT="$TIMEOUT_SECS" python3 - <<'PY'
import json, os, subprocess, sys, threading

codex = os.environ.get("CODEX_BIN", "codex")
timeout = int(os.environ.get("RPC_TIMEOUT", "30"))

proc = subprocess.Popen(
    [codex, "app-server", "--listen", "stdio://"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    text=True, bufsize=1,
)
if proc.stdin is None or proc.stdout is None:
    print("ERROR: cannot open codex app-server pipes", file=sys.stderr)
    sys.exit(1)

answer = {}
done = threading.Event()

def reader():
    try:
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if msg.get("id") == 2:
                answer["msg"] = msg
                done.set()
                return
    except Exception:
        pass

t = threading.Thread(target=reader, daemon=True)
t.start()

def send(obj):
    proc.stdin.write(json.dumps(obj) + "\n")
    proc.stdin.flush()

try:
    send({"method": "initialize", "id": 1,
          "params": {"clientInfo": {"name": "codex_limit_check",
                                    "title": "Codex limit check",
                                    "version": "1.0.0"}}})
    send({"method": "initialized"})
    send({"method": "account/rateLimits/read", "id": 2, "params": {}})
    if not done.wait(timeout):
        print("ERROR: timed out waiting for account/rateLimits/read", file=sys.stderr)
        sys.exit(1)
    print(json.dumps(answer["msg"]))
finally:
    try:
        proc.stdin.close()
    except Exception:
        pass
    try:
        proc.terminate()
    except Exception:
        pass
PY
}

# parse_5h_window <raw-json-file>: print "usedPercent resetsAt" for the 5h
# window, with resetsAt rendered as "null" when the backend reports none.
# Prints nothing (exit 1) when no 5h window is present at all.
parse_5h_window() {
    jq -r '
        (.result.rateLimits // .rateLimits // .result // {}) as $rl
        | (($rl.rateLimitsByLimitId // {}) | to_entries
           | map(select(.value.primary.windowDurationMins == 300)
                 | .value.primary) | first) as $byid
        | (if $byid != null then $byid
           elif ($rl.primary | type) == "object"
                and $rl.primary.windowDurationMins == 300 then $rl.primary
           else null end) as $w
        | if $w == null then empty
          else "\($w.usedPercent) \($w.resetsAt // "null")" end
    ' "$1"
}

# missing_reset <resetsAt>: true when no reset time was reported.
missing_reset() { local r=${1:-null}; [[ $r == "null" || $r == "0" || -z $r ]]; }

# normalize_used <value>: echo a numeric percent or 0 when unparseable.
normalize_used() {
    [[ ${1:-} =~ ^[0-9]+(\.[0-9]+)?$ ]] && printf '%s' "$1" || printf '0'
}

humanize_secs() {
    local total=$1
    if [[ $total -lt 0 ]]; then total=0; fi
    local d=$((total / 86400)) h=$(((total % 86400) / 3600)) m=$(((total % 3600) / 60))
    if [[ $d -gt 0 ]]; then printf '%dd %dh' "$d" "$h";
    elif [[ $h -gt 0 ]]; then printf '%dh %dm' "$h" "$m";
    else printf '%dm' "$m"; fi
}

take_snapshot() {
    # $1 = output file for raw JSON. Echoes "used resetsAt" (may be empty).
    local raw_file=$1 parsed
    fetch_ratelimits_raw >"$raw_file" \
        || die "failed to read rate limits from 'codex app-server' (is codex logged in? see: codex login)"
    [[ -s $raw_file ]] || die "empty response from codex app-server"
    parsed=$(parse_5h_window "$raw_file" || true)
    printf '%s' "$parsed"
}

now_epoch() { date +%s; }

# A 5h window must reset within 5h. A reset reported >= 5h away means the
# countdown is stuck (full window ahead of a live window is impossible).
# Both polls must agree — a single far-future read may be a transient glitch.
STUCK_AFTER_SECS=$((5 * 3600))

# far_reset <resetsAt> <now>: true when the reset is >= 5h in the future.
far_reset() {
    [[ ${1:-null} =~ ^[0-9]+$ ]] && [[ $(($1 - $2)) -ge $STUCK_AFTER_SECS ]]
}

# reset_agrees <reset1> <reset2>: true when snapshot 1 doesn't contradict a
# stuck snapshot 2 — i.e. it is missing, or within tolerance below it.
# ResetsAt jitters a few seconds between polls (and WAIT time passes), so an
# exact >= 5h match on both polls straddles the boundary forever; a genuine
# glitch/roll moves by minutes-to-hours and still counts as disagreeing.
STUCK_TOLERANCE_SECS=600
reset_agrees() {
    missing_reset "$1" && return 0
    [[ $1 =~ ^[0-9]+$ && $2 =~ ^[0-9]+$ ]] && [[ $1 -ge $(($2 - STUCK_TOLERANCE_SECS)) ]]
}

log_history() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$HISTORY_LOG"; }

RAW1="$STATE_DIR/snap1.json"
RAW2="$STATE_DIR/snap2.json"

vlog "snapshot 1/2 ..."
SNAP1=$(take_snapshot "$RAW1")
if [[ -z $SNAP1 ]]; then
    echo "No 5h window reported by codex (weekly-only account?). Nothing to do."
    log_history "no-5h-window"
    exit 0
fi
USED1=$(normalize_used "${SNAP1%% *}"); RESET1=${SNAP1##* }
vlog "snapshot1: used=${USED1}% resetsAt=${RESET1}"

if [[ $WAIT -gt 0 ]]; then
    vlog "sleeping ${WAIT}s before snapshot 2/2 ..."
    sleep "$WAIT"
fi

vlog "snapshot 2/2 ..."
SNAP2=$(take_snapshot "$RAW2")
if [[ -z $SNAP2 ]]; then
    echo "No 5h window reported by codex (weekly-only account?). Nothing to do."
    log_history "no-5h-window"
    exit 0
fi
USED2=$(normalize_used "${SNAP2%% *}"); RESET2=${SNAP2##* }
NOW=$(now_epoch)
vlog "snapshot2: used=${USED2}% resetsAt=${RESET2} now=${NOW}"

if missing_reset "$RESET2"; then
    printf '5h limit: %s%% used, reset time unavailable\n' "$USED2"
else
    LEFT=$((RESET2 - NOW))
    printf '5h limit: %s%% used, resets in %s (resetsAt=%s)\n' \
        "$USED2" "$(humanize_secs "$LEFT")" "$RESET2"
fi

# Idle with a healthy reset means no window is open — nothing to kick. But
# 0% with a STUCK reset (>= 5h away) still kicks: a live window never shows
# a full 5h reset, even an untouched one.
if [[ ${USED2%.*} == "0" ]] && { missing_reset "$RESET2" || ! far_reset "$RESET2" "$NOW"; }; then
    echo "Window idle (0% used). No kick needed."
    log_history "idle used=0 resetsAt=$RESET2"
    cp "$RAW2" "$STATE_DIR/last_snapshot.json"
    exit 0
fi

# A reported reset time means the countdown is scheduled. An unchanged
# resetsAt between polls is NORMAL (it is the window expiry, not a ticking
# clock), so on its own it must never trigger a kick. Just wait for reset —
# UNLESS the reset is >= 5h away, which a live 5h window can never show.
if ! missing_reset "$RESET2"; then
    LEFT2=$((RESET2 - NOW))
    if far_reset "$RESET2" "$NOW" && reset_agrees "$RESET1" "$RESET2"; then
        echo "Stuck 5h countdown detected (resets in $(humanize_secs "$LEFT2") >= 5h with ${USED2}% used)."
        log_history "stuck used=${USED2} resetsAt=$RESET2 left=${LEFT2}s wait=$WAIT"
    else
        if [[ $RESET2 -le $NOW ]]; then
            echo "Window already reset (resetsAt in the past). No kick needed."
        elif far_reset "$RESET2" "$NOW"; then
            echo "Reset jumped to >= 5h between polls (${RESET1} -> ${RESET2}); treating as transient. No kick."
        elif [[ ${USED2%.*} -ge 100 ]]; then
            echo "Limit exhausted, reset is scheduled. Waiting for reset — no kick (kicking would only burn more quota)."
        elif [[ $RESET1 != "$RESET2" ]]; then
            echo "Countdown active (resetsAt ${RESET1} -> ${RESET2}). No kick needed."
        else
            echo "Countdown scheduled (resetsAt=${RESET2}). No kick needed."
        fi
        log_history "scheduled used=${USED2} resetsAt=$RESET2"
        cp "$RAW2" "$STATE_DIR/last_snapshot.json"
        exit 0
    fi
fi

# No reset time in snapshot 2 (stuck case above skips this whole block and
# falls straight through to the kick). Only kick when BOTH snapshots lack
# it — a single missing read may be a transient glitch.
if missing_reset "$RESET2"; then
    if ! missing_reset "$RESET1"; then
        echo "Reset time vanished between polls (${RESET1} -> unavailable); treating as transient. No kick."
        log_history "transient used=${USED2} resetsAt1=$RESET1 resetsAt2=$RESET2"
        cp "$RAW2" "$STATE_DIR/last_snapshot.json"
        exit 0
    fi

    # Usage without any reset time in both polls: countdown never scheduled.
    echo "Unscheduled 5h countdown detected (${USED2}% used, no resetsAt in ${WAIT}s of polls)."
    log_history "unscheduled used=${USED2} wait=$WAIT"
fi

if [[ $DRY_RUN == true || $NO_KICK == true ]]; then
    echo "Dry run: would send cheap-model kick (model=$MODEL). No request sent."
    cp "$RAW2" "$STATE_DIR/last_snapshot.json"
    exit 0
fi

echo "Sending cheap-model kick: codex exec --model $MODEL ..."

# Run "$@" under `timeout` when available.
_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        "$@"
    fi
}

# run_kick: send the cheap-model request. Current CLIs reject
# `--ask-for-approval` AFTER `exec` ("unexpected argument ... found"), so the
# approval flag goes BEFORE the subcommand — and `exec` already defaults to
# never-ask headless runs anyway. Flag sets are tried from most explicit to
# most minimal, falling back ONLY when the CLI rejects a flag (exit 2 +
# clap error); any other failure is a real kick failure. Flag rejections
# happen before any API call, so retries never consume quota.
KICK_ATTEMPT=""
run_kick() {
    local mode out rc
    for mode in GLOBAL_APPROVAL EXEC_FLAGS MINIMAL; do
        case $mode in
            GLOBAL_APPROVAL)
                set -- "$CODEX_BIN" --ask-for-approval never exec \
                    --model "$MODEL" --sandbox read-only \
                    --skip-git-repo-check "$EXEC_PROMPT" ;;
            EXEC_FLAGS)
                set -- "$CODEX_BIN" exec --model "$MODEL" \
                    --sandbox read-only --skip-git-repo-check "$EXEC_PROMPT" ;;
            MINIMAL)
                set -- "$CODEX_BIN" exec --model "$MODEL" "$EXEC_PROMPT" ;;
        esac
        vlog "kick attempt ($mode): $*"
        # NOTE: do NOT use `if out=$(...); then ... fi; rc=$?` here — after an
        # if with no else whose condition failed, $? is 0 (POSIX), not the
        # condition's status. Capture via || instead.
        rc=0
        out=$(_with_timeout "$@" 2>&1) || rc=$?
        if [[ $rc -eq 0 ]]; then
            vlog "$out"
            KICK_ATTEMPT=$mode
            return 0
        fi
        if [[ $rc -eq 2 && $out == *"unexpected argument"* ]]; then
            vlog "flag rejected, falling back: $out"
            continue
        fi
        printf '%s\n' "$out" >&2
        return "$rc"
    done
    printf '%s\n' "$out" >&2
    return "$rc"
}

rc=0
run_kick || rc=$?
[[ $rc -eq 0 ]] || die "kick request failed (codex exec exit $rc)"
vlog "kick accepted via flag set: ${KICK_ATTEMPT:-unknown}"

# Re-read once to show the post-kick state (best effort, never fatal).
if take_snapshot "$STATE_DIR/snap3.json" >/tmp/codex_kick_post.$$ 2>/dev/null; then
    POST=$(cat /tmp/codex_kick_post.$$)
    rm -f /tmp/codex_kick_post.$$
    if [[ -n $POST ]]; then
        echo "Post-kick 5h window: $POST"
        log_history "kicked model=$MODEL prompt='$EXEC_PROMPT' before_resetsAt=$RESET2 after='$POST'"
    else
        log_history "kicked model=$MODEL prompt='$EXEC_PROMPT' before_resetsAt=$RESET2"
    fi
else
    rm -f /tmp/codex_kick_post.$$
    log_history "kicked model=$MODEL prompt='$EXEC_PROMPT' before_resetsAt=$RESET2 (post re-read failed)"
fi
cp "$RAW2" "$STATE_DIR/last_snapshot.json" 2>/dev/null || true
echo "Kick sent with $MODEL."
