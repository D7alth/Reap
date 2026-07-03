# shellcheck shell=bash
# state.sh — generic save/restore with idempotency guard (RNF-01, RNF-03).
# One key == one file under the state dir. save_once never overwrites an
# existing backup, so running 'gaming' twice can't record an already-optimized
# value as if it were the original (spec §5, bug B-idempotency).

: "${REAP_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/reap}"

state::init() {
  mkdir -p "$REAP_STATE_DIR"
  chmod 700 "$REAP_STATE_DIR" 2>/dev/null || true
}

state::path() { printf '%s/%s' "$REAP_STATE_DIR" "$1"; }

state::has() { [[ -f "$(state::path "$1")" ]]; }

state::save_once() {
  local key="$1" value="$2" file
  file="$(state::path "$key")"
  if [[ -f "$file" ]]; then
    log::info "state '$key' already saved — keeping original backup"
    return 0
  fi
  state::init
  printf '%s\n' "$value" >"$file"
  log::info "state '$key' saved ($value)"
}

state::load() {
  local file
  file="$(state::path "$1")"
  [[ -f "$file" ]] || return 1
  cat "$file"
}

state::clear() { rm -f "$(state::path "$1")"; }
