# shellcheck shell=bash
# core.sh — dispatch, lock, and the two V1 commands (spec §4.1, §6).
# Assumes every other module is already sourced by bin/reap.

reap::_acquire_lock() {
  # RNF-06: flock prevents two concurrent reap runs from corrupting state.
  state::init
  exec 9>"$(state::path reap.lock)"
  if ! flock -n 9; then
    log::error "another reap instance is running — aborting"
    exit 1
  fi
}

reap::_has_optimizer_state() {
  state::has vm-swappiness || state::has cpu-governor || state::has ppd-profile
}

reap::gaming() {
  reap::_acquire_lock
  journal::start gaming
  log::info "=== reap gaming: freeing resources ==="
  sudo::preflight || exit 1
  svc::stop_configured
  app::stop_all
  registry::apply_all
  log::info "=== gaming mode ON — run 'reap exit' when you're done ==="
  notify::send "reap: gaming mode ON" "Services stopped, optimizations applied."
  return 0
}

reap::exit() {
  reap::_acquire_lock
  journal::start exit
  log::info "=== reap exit: restoring system ==="
  # RF-05 + bug B3: with no saved state, never start services blindly — warn only.
  if ! state::has "$REAP_ACTIVE_SERVICES_KEY" && ! reap::_has_optimizer_state; then
    log::warn "no saved state found — nothing to restore (did you run 'reap gaming'?)"
    return 0
  fi
  sudo::preflight || exit 1
  if ! svc::restore; then
    log::info "no saved service list — services left as-is"
  fi
  registry::revert_all
  log::info "=== gaming mode OFF — restore complete; reopen your apps manually ==="
  notify::send "reap: gaming mode OFF" "Services and kernel settings restored."
  return 0
}

reap::help() {
  cat <<'EOF'
reap — free up system resources for gaming, then restore everything.

Usage:
  reap gaming   stop non-essential services/apps + apply optimizations
  reap exit     restore everything 'gaming' changed (no-op if no saved state)
  reap status   show whether gaming mode is active, what changed, recent runs
  reap help     show this help

State and the execution journal (last 10 runs) are kept in
${XDG_STATE_HOME:-$HOME/.local/state}/reap/.
Service and app sets are defined in lib/services.sh and lib/apps.sh.
EOF
}

reap::main() {
  local command="${1:-help}"
  case "$command" in
    gaming) reap::gaming ;;
    exit) reap::exit ;;
    status) reap::status ;;
    help | -h | --help) reap::help ;;
    *)
      log::error "unknown command: $command"
      reap::help
      return 1
      ;;
  esac
}
