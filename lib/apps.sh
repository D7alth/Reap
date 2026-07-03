# shellcheck shell=bash
# apps.sh — graceful shutdown of background apps (RF-02, RC-04, bug B6).
# SIGTERM + generous grace period; SIGKILL is opt-in (REAP_ALLOW_SIGKILL) and
# never sent to apps flagged sensitive (potential unsaved work).

readonly REAP_APPS=(
  jetbrains-toolbox
  rider
  idea
  code
  code-oss
  visual-studio-code
  firefox
  chrome
  chromium
)

# Apps that may hold unsaved work — SIGKILL is never sent to these (RC-04).
readonly REAP_SENSITIVE_APPS=(
  jetbrains-toolbox
  rider
  idea
  code
  code-oss
  visual-studio-code
)

readonly REAP_APP_GRACE_SECONDS=8
: "${REAP_ALLOW_SIGKILL:=0}"

app::_regex_escape() {
  printf '%s' "$1" | sed -e 's/[][(){}.^$*+?|\\/]/\\&/g'
}

app::pids() {
  local escaped
  escaped="$(app::_regex_escape "$1")"
  pgrep -f -- "(^|/)${escaped}([[:space:]]|$)" 2>/dev/null || true
}

app::_is_sensitive() {
  local app="$1" entry
  for entry in "${REAP_SENSITIVE_APPS[@]}"; do
    [[ "$app" == "$entry" ]] && return 0
  done
  return 1
}

app::_signal() {
  local sig="$1" pids="$2" pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill "-$sig" "$pid" 2>/dev/null || true
  done <<<"$pids"
}

app::_wait_gone() {
  local app="$1" waited=0
  while ((waited < REAP_APP_GRACE_SECONDS)); do
    [[ -z "$(app::pids "$app")" ]] && return 0
    sleep 1
    ((waited++))
  done
  [[ -z "$(app::pids "$app")" ]]
}

app::stop_all() {
  local app pids
  for app in "${REAP_APPS[@]}"; do
    pids="$(app::pids "$app")"
    [[ -n "$pids" ]] || continue

    log::info "stopping app '$app' (SIGTERM): $(tr '\n' ' ' <<<"$pids")"
    app::_signal TERM "$pids"

    if app::_wait_gone "$app"; then
      log::info "'$app' exited gracefully"
      continue
    fi

    pids="$(app::pids "$app")"
    if ((REAP_ALLOW_SIGKILL)) && ! app::_is_sensitive "$app"; then
      log::warn "'$app' still running after ${REAP_APP_GRACE_SECONDS}s — sending SIGKILL"
      app::_signal KILL "$pids"
    else
      log::warn "'$app' still running after ${REAP_APP_GRACE_SECONDS}s — left alone (SIGKILL disabled or app is sensitive)"
    fi
  done
  return 0
}
