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
    log::error "usage: reap play <game> [args…]"
    return 1
  fi
  if ! gpu::_resolve_game "$1"; then
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
  log::info "=== reap play: starting gaming session for '$1' ==="
  sudo::preflight || exit 1

  # From here state may change → arm restore before mutating anything (RNF-01).
  REAP_PLAY_ACTIVE=1
  trap 'reap::_play_cleanup' EXIT
  trap 'reap::_play_cleanup; exit 130' INT
  trap 'reap::_play_cleanup; exit 143' TERM

  svc::stop_configured
  app::stop_all
  registry::apply_all

  local rc=0
  log::info "=== game launching — session stays active until it exits ==="
  notify::send "reap: gaming session ON" "Launching $1 on the dGPU."
  gpu::launch "$@" || rc=$?
  log::info "=== game exited (rc=$rc) ==="
  return "$rc"
}
