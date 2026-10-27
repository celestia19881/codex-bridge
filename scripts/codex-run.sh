#!/usr/bin/env bash
# codex-run.sh — POSIX port of codex-run.ps1.
#
# STATUS: best-effort. The PowerShell script is the one battle-tested on Windows;
# this port reuses the same CLI contract but has seen less real traffic. The
# Windows-specific traps in references/windows-gotchas.md do NOT apply here
# (plain file redirection works on POSIX), so this script is much smaller.
#
# Requires: codex CLI (CODEX_CLI, `codex` on PATH, or the desktop app's bundle),
#           bash 3.2+, python3 or python (for event parsing; falls back to grep).
#
# Usage:
#   ./codex-run.sh -D                       # preflight report (doctor)
#   ./codex-run.sh -x -t "hi"               # dry run: print the argv, run nothing
#   ./codex-run.sh -l                       # list sessions
#   ./codex-run.sh -t "reply PONG" -s read-only
#   ./codex-run.sh -p prompt.txt -d /work/out -j -n 1200
#   ./codex-run.sh -r <session> -t "keep going"
#   ./codex-run.sh -r <session> -t "keep going" -R events.jsonl   # replay offline
set -uo pipefail

PROMPT_FILE=""; PROMPT_TEXT=""; WORKDIR="$(pwd)"; SANDBOX="workspace-write"
MODEL=""; SESSION=""; QUEUE=""; LIST=0; OUTFILE=""; TIMEOUT=300
JSON=0; DRYRUN=0; DOCTOR=0; REPLAY=""; CODEX_CLI="${CODEX_CLI:-}"; LAST=0; PERSIST=0

die() { printf '[codex-run] ERROR: %s\n' "$2" >&2; exit "$1"; }

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while getopts ":p:t:d:s:m:r:q:lo:n:jDxR:Pc:h" opt; do
  case "$opt" in
    p) PROMPT_FILE="$OPTARG" ;;
    t) PROMPT_TEXT="$OPTARG" ;;
    d) WORKDIR="$OPTARG" ;;
    s) SANDBOX="$OPTARG" ;;
    m) MODEL="$OPTARG" ;;
    r) SESSION="$OPTARG" ;;
    q) QUEUE="$OPTARG" ;;
    l) LIST=1 ;;
    o) OUTFILE="$OPTARG" ;;
    n) TIMEOUT="$OPTARG" ;;
    j) JSON=1 ;;
    D) DOCTOR=1 ;;
    x) DRYRUN=1 ;;
    R) REPLAY="$OPTARG" ;;
    P) PERSIST=1 ;;
    c) CODEX_CLI="$OPTARG" ;;
    h) usage 0 ;;
    :) die 5 "option -$OPTARG needs a value." ;;
    \?) die 5 "unknown option -$OPTARG (try -h)." ;;
  esac
done

# ------------------------------------------------------------------ python
PY=""
# Prefer python over python3: on Windows the Microsoft Store ships a "python3"
# alias that resolves, wins command -v, and silently does nothing.
for cand in "${PYTHON:-}" python python3 py; do
  [ -n "$cand" ] || continue
  command -v "$cand" >/dev/null 2>&1 || continue
  if "$cand" -c 'import sys' >/dev/null 2>&1; then PY="$cand"; break; fi
done

# ------------------------------------------------------------------ discovery
if [ -z "$CODEX_CLI" ] || [ ! -x "$CODEX_CLI" ]; then
  CODEX_CLI=""
  if command -v codex >/dev/null 2>&1; then
    CODEX_CLI="$(command -v codex)"
  else
    for root in "${LOCALAPPDATA:-}/OpenAI/Codex/bin" "$HOME/.codex/bin" \
                "$HOME/Library/Application Support/OpenAI/Codex/bin"; do
      [ -d "$root" ] || continue
      hit="$(ls -1t "$root"/*/codex "$root"/*/codex.exe "$root"/codex "$root"/codex.exe 2>/dev/null | head -n 1)"
      [ -n "$hit" ] && { CODEX_CLI="$hit"; break; }
    done
  fi
fi

# CODEX_HOME defaults to the real user profile, not bash's $HOME (on Git Bash /
# MSYS they differ, and the wrong one looks like a logged-out install).
if [ -n "${USERPROFILE:-}" ]; then
  _up="${USERPROFILE//\\//}"
  CX_HOME_DIR="${CODEX_HOME:-$_up/.codex}"
else
  CX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
fi

doctor() {
  printf '%-15s %s\n' cli "${CODEX_CLI:-(not found)}"
  if [ -n "$CODEX_CLI" ]; then
    printf '%-15s %s\n' version "$("$CODEX_CLI" --version 2>&1 | head -n 1)"
  else
    printf '%-15s %s\n' version -
  fi
  printf '%-15s %s\n' codexHome "$CX_HOME_DIR"
  if [ -f "$CX_HOME_DIR/auth.json" ]; then
    printf '%-15s %s\n' auth "present, $(wc -c < "$CX_HOME_DIR/auth.json" | tr -d ' ') bytes"
  else
    printf '%-15s %s\n' auth 'MISSING -> run: codex login'
  fi
  if [ -f "$CX_HOME_DIR/config.toml" ]; then
    printf '%-15s %s\n' config present
    grep -E '^\s*(model_provider|model|wire_api|sandbox)\s*=' "$CX_HOME_DIR/config.toml" 2>/dev/null | sed 's/^/cfg             /'
  else
    printf '%-15s %s\n' config 'missing (defaults apply)'
  fi
  if [ -f "$CX_HOME_DIR/session_index.jsonl" ]; then
    printf '%-15s %s\n' sessions "$(grep -c . "$CX_HOME_DIR/session_index.jsonl" 2>/dev/null || echo 0)"
  else
    printf '%-15s %s\n' sessions 0
  fi
  printf '%-15s %s\n' proxy "${https_proxy:-${HTTPS_PROXY:-none}}"
  [ -n "$CODEX_CLI" ] || exit 4
}

[ "$DOCTOR" -eq 1 ] && { doctor; exit 0; }

if [ -z "$CODEX_CLI" ]; then
  die 4 'codex CLI not found. Pass -c <path> or set CODEX_CLI.'
fi

# ------------------------------------------------------------------ list
if [ "$LIST" -eq 1 ]; then
  idx="$CX_HOME_DIR/session_index.jsonl"
  [ -f "$idx" ] || die 4 "no session index at $idx"
  if [ "$JSON" -eq 1 ] && [ -n "$PY" ]; then
    "$PY" - "$idx" <<'PY'
import json,sys
rows=[]
for line in open(sys.argv[1],encoding='utf-8',errors='replace'):
    line=line.strip()
    if not line: continue
    try: o=json.loads(line)
    except Exception: continue
    rows.append({"session":o.get("id"),"name":o.get("thread_name"),"updated":o.get("updated_at")})
rows.sort(key=lambda r:(r["updated"] or ""),reverse=True)
print(json.dumps(rows,ensure_ascii=False))
PY
    exit 0
  fi
  printf '%-38s  %-20s  %s\n' SESSION UPDATED NAME
  "$PY" - "$idx" <<'PY'
import json,sys
rows=[]
for line in open(sys.argv[1],encoding='utf-8',errors='replace'):
    line=line.strip()
    if not line: continue
    try: o=json.loads(line)
    except Exception: continue
    rows.append((o.get("updated_at") or "",o.get("id") or "",o.get("thread_name") or ""))
for u,i,n in sorted(rows,reverse=True):
    print("%-38s  %-20s  %s"%(i,u[:19],n))
PY
  exit 0
fi

# ------------------------------------------------------------------ prompt
prompt=""
[ -n "$PROMPT_FILE" ] && { [ -f "$PROMPT_FILE" ] || die 5 "prompt file not found: $PROMPT_FILE"; prompt="$(cat "$PROMPT_FILE")"; }
[ -z "$prompt" ] && [ -n "$PROMPT_TEXT" ] && prompt="$PROMPT_TEXT"
[ -z "$prompt" ] && [ "$PROMPT_FILE" = "-" ] && prompt="$(cat)"

if [ -z "$prompt" ] && [ -z "$REPLAY" ]; then
  die 5 'no prompt. Use -p file, -t text, or -p - for stdin.'
fi

# ------------------------------------------------------------------ args
args=()
mode="exec"
if [ -n "$QUEUE" ]; then
  mode="queue"; args+=(queue --thread "$QUEUE" --message "$prompt")
elif [ -n "$SESSION" ]; then
  mode="resume"; args+=(exec resume "$SESSION" --json --skip-git-repo-check)
  [ -n "$MODEL" ] && args+=(-m "$MODEL")
  [ -n "$OUTFILE" ] && args+=(-o "$OUTFILE")
  args+=(-)
else
  args+=(exec --json --skip-git-repo-check -C "$WORKDIR" -s "$SANDBOX")
  [ "$PERSIST" -eq 1 ] || args+=(--ephemeral)
  [ -n "$MODEL" ] && args+=(-m "$MODEL")
  [ -n "$OUTFILE" ] && args+=(-o "$OUTFILE")
  args+=(-)
fi

if [ "$DRYRUN" -eq 1 ]; then
  printf 'CLI : %s\nARGS: %s\nWD  : %s\nSBX : %s\n' "$CODEX_CLI" "${args[*]}" "$WORKDIR" "$SANDBOX"
  exit 0
fi

# ------------------------------------------------------------------ run
run_dir="${TMPDIR:-/tmp}/codex-run-$$"
mkdir -p "$run_dir" || die 3 "cannot create $run_dir"
in_file="$run_dir/in.txt"; out_file="$run_dir/out.jsonl"; err_file="$run_dir/err.log"
printf '%s' "$prompt" > "$in_file"

ec=0
started=$(date +%s)
if [ -n "$REPLAY" ]; then
  [ -f "$REPLAY" ] || die 5 "replay file not found: $REPLAY"
  cp "$REPLAY" "$out_file"; : > "$err_file"
else
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT" "$CODEX_CLI" "${args[@]}" < "$in_file" > "$out_file" 2> "$err_file"
    ec=$?
    [ "$ec" -eq 124 ] && ec=2
  else
    "$CODEX_CLI" "${args[@]}" < "$in_file" > "$out_file" 2> "$err_file" &
    cpid=$!; waited=0
    while kill -0 "$cpid" 2>/dev/null; do
      sleep 2; waited=$((waited+2))
      if [ "$waited" -ge "$TIMEOUT" ]; then kill -TERM "$cpid" 2>/dev/null; ec=2; break; fi
    done
    wait "$cpid" 2>/dev/null; [ "$ec" -eq 0 ] && ec=$?
  fi
fi
elapsed=$(( $(date +%s) - started ))

# ------------------------------------------------------------------ parse
parsed=""
if [ -n "$PY" ]; then
  parsed="$("$PY" - "$out_file" "$ec" "$elapsed" "$JSON" "$mode" "$SANDBOX" 2>/dev/null <<'PY'
import json,sys
path,ec,elapsed,as_json,mode,sandbox=sys.argv[1],int(sys.argv[2]),float(sys.argv[3]),int(sys.argv[4]),sys.argv[5],sys.argv[6]
msgs=[];cmds=[];errors=[];soft=0;usage=None;session=None;completed=False
for line in open(path,encoding='utf-8',errors='replace'):
    line=line.strip()
    if not line: continue
    try: d=json.loads(line)
    except Exception: continue
    t=d.get("type")
    if t=="thread.started": session=d.get("thread_id")
    elif t=="turn.completed": completed=True; usage=d.get("usage")
    elif t=="error":
        m=str(d.get("message",""))
        if "Reconnecting" in m or "timed out" in m: soft+=1
        else: errors.append(m)
    elif t=="item.completed":
        it=d.get("item") or {}
        if it.get("type")=="agent_message": msgs.append(it.get("text",""))
        elif it.get("type")=="command_execution": cmds.append({"command":it.get("command"),"exitCode":it.get("exit_code")})
ok = (ec==0 and completed)
res={"ok":ok,"mode":mode,"sandbox":sandbox,"exitCode":ec,"sessionId":session,
     "message":(msgs[-1] if msgs else ""),"messageCount":len(msgs),"commands":cmds,
     "commandCount":len(cmds),"usage":usage,"errors":errors,"elapsedSec":elapsed}
if as_json: print(json.dumps(res,ensure_ascii=False))
else:
    print("[codex-run] %s  mode=%s  sandbox=%s  exit=%d  %.0fs" % ("OK" if ok else "FAIL",mode,sandbox,ec,elapsed))
    if session: print("session: %s"%session)
    if cmds:
        print("commands run: %d"%len(cmds))
        for c in cmds: print("  [%s] %s"%(c["exitCode"],str(c["command"])[:110]))
    if res["message"]:
        print(""); print("--- reply ---"); print(res["message"])
sys.exit(0 if ok else 3)
PY
)"
  rc=$?
else
  grep -o '"type":"error","message":"[^"]*"' "$out_file" 2>/dev/null | head -n 3
  grep -o '"text":"[^"]*"' "$out_file" 2>/dev/null | tail -n 1
  parsed=""
  rc=3
fi

[ -n "$parsed" ] && printf '%s\n' "$parsed"
if [ -s "$err_file" ]; then
  printf '\n--- stderr (tail) ---\n' >&2
  tail -n 5 "$err_file" >&2
fi
if [ ! -f "$REPLAY" ] && [ -s "$err_file" ] && grep -q 'workspace routing' "$err_file" 2>/dev/null; then
  printf '[codex-run] hint: network to chatgpt.com looks blocked; start the local proxy.\n' >&2
fi
rm -rf "$run_dir"
exit "${rc:-3}"
