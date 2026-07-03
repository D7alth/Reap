# shellcheck shell=bash
# gamemode.sh — preferred optimizer (spec §4.3, RF-03).
# reap does not reimplement CPU/IO/priority tuning: when Feral GameMode is
# installed it owns those, applied when the game launches via 'gamemoderun'.
# Its presence is what makes the cpu/vm fallback optimizers stand down.

gamemode::is_available() {
  command -v gamemoderun >/dev/null 2>&1 || command -v gamemoded >/dev/null 2>&1
}

gamemode::apply() {
  if gamemode::is_available; then
    log::info "GameMode detected — CPU/IO/priority delegated to it; launch your game with 'gamemoderun <game>'"
  else
    log::info "GameMode not installed — manual fallback optimizers will handle CPU/VM"
  fi
  return 0
}

gamemode::revert() { return 0; }

registry::register gamemode gamemode::apply gamemode::revert
