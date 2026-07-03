# shellcheck shell=bash
# journal.sh — persistent, structured execution log (spec §9 v1.1).
# One JSONL file; each line is a fully-declared object:
#   {"ts":"…","session":"…","cmd":"gaming|exit","level":"info|warn|error","msg":"…"}
# Retention is by execution, not size: only the last REAP_LOG_MAX_SESSIONS
# sessions are kept (pruned on session start, under the caller's flock).
# A journal write never aborts the operation it records — observability must not
# break resource management; write failures warn to stderr and continue.

: "${REAP_LOG_MAX_SESSIONS:=10}"

journal::_file() {
  printf '%s' "${REAP_LOG_FILE:-${REAP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/reap}/executions.jsonl}"
}

journal::_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

# Begin a new execution: assign a session id, prune old sessions, mark the start.
journal::start() {
  local cmd="$1" file
  REAP_SESSION_ID="$(date +%Y%m%dT%H%M%S)-$$"
  REAP_SESSION_CMD="$cmd"
  file="$(journal::_file)"
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  journal::prune "$((REAP_LOG_MAX_SESSIONS - 1))"
  journal::append info "session_start pid=$$ cmd=$cmd"
}

journal::append() {
  [[ -n "${REAP_SESSION_ID:-}" ]] || return 0
  local level="$1" file ts msg
  shift
  msg="$(journal::_json_escape "$*")"
  file="$(journal::_file)"
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  if ! printf '{"ts":"%s","session":"%s","cmd":"%s","level":"%s","msg":"%s"}\n' \
    "$ts" "$REAP_SESSION_ID" "${REAP_SESSION_CMD:-?}" "$level" "$msg" >>"$file" 2>/dev/null; then
    printf 'reap: warning: could not write journal at %s\n' "$file" >&2
  fi
  return 0
}

# Keep only the last N distinct sessions (in first-appearance order).
journal::prune() {
  local keep="${1:-$REAP_LOG_MAX_SESSIONS}" file tmp
  file="$(journal::_file)"
  [[ -f "$file" ]] || return 0
  tmp="${file}.tmp.$$"
  if awk -v keep="$keep" '
      { line[NR] = $0 }
      match($0, /"session":"[^"]*"/) {
        s = substr($0, RSTART + 11, RLENGTH - 12)
        sess[NR] = s
        if (!(s in seen)) { seen[s] = 1; order[++n] = s }
      }
      END {
        start = (n > keep) ? n - keep + 1 : 1
        for (i = start; i <= n; i++) keepset[order[i]] = 1
        for (r = 1; r <= NR; r++) if (sess[r] in keepset) print line[r]
      }
    ' "$file" >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$file"
  else
    rm -f "$tmp"
  fi
  return 0
}

# One summary row per session (last N), most recent last:
#   <session>  <cmd>  <first-ts>  <ok|warnings|errors>
journal::summary() {
  local n="${1:-$REAP_LOG_MAX_SESSIONS}" file
  file="$(journal::_file)"
  if [[ ! -f "$file" || ! -s "$file" ]]; then
    printf '  (no executions logged yet)\n'
    return 0
  fi
  awk -v n="$n" '
    match($0, /"session":"[^"]*"/) { s = substr($0, RSTART + 11, RLENGTH - 12) }
    match($0, /"cmd":"[^"]*"/)     { c = substr($0, RSTART + 7,  RLENGTH - 8) }
    match($0, /"ts":"[^"]*"/)      { t = substr($0, RSTART + 6,  RLENGTH - 7) }
    match($0, /"level":"[^"]*"/)   { l = substr($0, RSTART + 9,  RLENGTH - 10) }
    {
      if (!(s in seen)) { seen[s] = 1; order[++cnt] = s; cmd[s] = c; first_ts[s] = t }
      if (l == "error") err[s]++
      else if (l == "warn") warn[s]++
    }
    END {
      start = (cnt > n) ? cnt - n + 1 : 1
      for (i = start; i <= cnt; i++) {
        se = order[i]
        result = (err[se] > 0) ? "errors" : ((warn[se] > 0) ? "warnings" : "ok")
        printf "  %-22s %-7s %-25s %s\n", se, cmd[se], first_ts[se], result
      }
    }
  ' "$file"
}
