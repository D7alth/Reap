# shellcheck shell=bash
# play.sh — `reap play <game> [args…]` session orchestrator (spec-play.md).
# One command = a full gaming session: stop services/apps + apply optimizations
# (like 'gaming'), launch the game on the dGPU (gpu::launch, blocking), then
# restore everything (like 'exit') when the game exits — automatically, and even
# on Ctrl-C / crash, via a trap. RNF-01 (reversibility) must hold no matter how
# the game process ends, so the restore path is armed before any state is mutated.

# Idempotent restore: safe to run once. The EXIT trap always fires; INT/TERM also
# fire it and then exit, so the flag guard makes the second EXIT pass a no-op.
reap::_play_cleanup() {
  [[ "${REAP_PLAY_ACTIVE:-0}" == "1" ]] || return 0
  REAP_PLAY_ACTIVE=0
  # RC-04 spirit: the game is Steam's child, not ours — reap never kills it.
  if [[ "${REAP_PLAY_TARGET:-}" == "steam" && -n "${REAP_STEAM_GAME_DIR:-}" && -n "$(steam::_game_pids)" ]]; then
    log::warn "play: game still running — restoring system underneath it (reap never kills the game)"
  fi
  log::info "=== reap play: restoring system ==="
  if ! svc::restore; then
    log::info "no saved service list — services left as-is"
  fi
  registry::revert_all
  log::info "=== gaming mode OFF — session complete; reopen your apps manually ==="
  notify::send "reap: session ended" "Services and kernel settings restored."
  return 0
}

reap::play() {
  if (($# == 0)); then
    log::error "usage: reap play <game|steam:appid> [args…]"
    return 1
  fi

  # Fail-fast resolution (before any lock/sudo/state): a target we can't launch
  # must never cost a stopped service.
  local steam_appid=""
  steam_appid="$(steam::parse_target "$1")" || steam_appid=""
  if [[ -n "$steam_appid" ]]; then
    if ! command -v steam >/dev/null 2>&1; then
      log::error "steam client not found on PATH — cannot launch appid $steam_appid"
      return 1
    fi
    if ! steam::resolve "$steam_appid"; then
      log::error "appid $steam_appid is not installed in any Steam library — nothing launched"
      return 1
    fi
    (($# > 1)) && log::warn "steam target: extra arguments ignored — set them in the game's Steam Launch Options"
  elif ! gpu::_resolve_game "$1"; then
    log::error "game '$1' not found (not on PATH, not an executable) — nothing launched"
    return 1
  fi

  reap::_acquire_lock
  # A play session must start from a clean slate, or restore would touch state it
  # didn't create. Refuse to stack on an existing gaming session.
  if state::has "$REAP_ACTIVE_SERVICES_KEY" || reap::_has_optimizer_state; then
    log::error "a gaming session is already active — run 'reap exit' before 'reap play'"
    return 1
  fi

  journal::start play
  local target_label="$1"
  [[ -n "$steam_appid" ]] && target_label="$REAP_STEAM_GAME_NAME (steam appid $steam_appid)"
  log::info "=== reap play: starting gaming session for '$target_label' ==="
  sudo::preflight || exit 1

  # From here state may change → arm restore before mutating anything (RNF-01).
  REAP_PLAY_ACTIVE=1
  REAP_PLAY_TARGET="binary"
  [[ -n "$steam_appid" ]] && REAP_PLAY_TARGET="steam"
  trap 'reap::_play_cleanup' EXIT
  trap 'reap::_play_cleanup; exit 130' INT
  trap 'reap::_play_cleanup; exit 143' TERM

  svc::stop_configured
  app::stop_all
  registry::apply_all

  local rc=0
  log::info "=== game launching — session stays active until it exits ==="
  notify::send "reap: gaming session ON" "Launching $target_label."
  if [[ -n "$steam_appid" ]]; then
    steam::launch_and_wait "$steam_appid" || rc=$?
    log::info "=== session ended (rc=$rc; game exit code not observable via Steam) ==="
  else
    gpu::launch "$@" || rc=$?
    log::info "=== game exited (rc=$rc) ==="
  fi
  return "$rc"
}
