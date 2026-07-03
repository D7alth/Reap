# shellcheck shell=bash
# log.sh — structured stdout/stderr logging. No side effects on source (RNF-04).
# V1 logs to the console only; persistent session logs are roadmap (spec §9).

log::_emit() {
  local level="$1" stream="$2"
  shift 2
  printf '%s [%-5s] %s\n' "$(date '+%H:%M:%S')" "$level" "$*" >"$stream"
  # Mirror to the persistent journal when an execution session is active.
  if [[ -n "${REAP_SESSION_ID:-}" ]] && declare -F journal::append >/dev/null 2>&1; then
    journal::append "${level,,}" "$*"
  fi
}

log::info() { log::_emit "INFO" /dev/stdout "$@"; }
log::warn() { log::_emit "WARN" /dev/stderr "$@"; }
log::error() { log::_emit "ERROR" /dev/stderr "$@"; }

# Best-effort desktop notification — never fails the caller if absent.
notify::send() {
  command -v notify-send >/dev/null 2>&1 && notify-send "$1" "$2" >/dev/null 2>&1
  return 0
}
