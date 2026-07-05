# shellcheck shell=bash
# gpu-clock.sh — pin NVIDIA PowerMizer to max performance during gaming
# (spec-fps-fix.md F1). Root cause of the ELDEN RING NIGHTREIGN fps collapse was
# GPUPowerMizerMode=0 (Adaptive) letting the GPU clock stick in a low perf state
# under load (the "alt-tab restores 60fps" signature). Pinning mode=1 (Prefer
# Maximum Performance) holds perf level 3. Set via nvidia-settings on the user's X
# session — no sudo (it's an NV-CONTROL attribute, not sysfs) — and fully
# reversible: the original mode is saved and restored on exit (RNF-01).

readonly REAP_POWERMIZER_KEY="gpu-powermizer"
readonly REAP_POWERMIZER_MAX_PERF=1 # 0=Adaptive, 1=Prefer Max Performance, 2=Auto

gpuclock::_is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

# nvidia-settings needs a graphical X session. Prefer the inherited env; otherwise
# borrow DISPLAY/XAUTHORITY from the user's gnome-shell (same UID).
gpuclock::_ensure_display() {
  [[ -n "${DISPLAY:-}" && -n "${XAUTHORITY:-}" ]] && return 0
  local pid disp xauth
  pid="$(pgrep -u "$UID" -x gnome-shell 2>/dev/null | head -1)"
  [[ -n "$pid" ]] || return 1
  disp="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^DISPLAY=//p' | head -1)"
  xauth="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^XAUTHORITY=//p' | head -1)"
  [[ -n "$disp" ]] || return 1
  export DISPLAY="$disp"
  [[ -n "$xauth" ]] && export XAUTHORITY="$xauth"
  return 0
}

gpuclock::_available() {
  command -v nvidia-settings >/dev/null 2>&1 || return 1
  gpu::_has_dgpu || return 1
  gpuclock::_ensure_display || return 1
  return 0
}

gpuclock::_query_mode() { nvidia-settings -q '[gpu:0]/GPUPowerMizerMode' -t 2>/dev/null | head -1; }

gpuclock::apply() {
  if ! gpuclock::_available; then
    log::info "gpu-clock: nvidia-settings/dGPU/X session unavailable — skipping PowerMizer pin"
    return 0
  fi
  # RNF-05: don't sustain forced performance without thermald / within temp limit.
  if ! thermal::guard; then
    log::warn "gpu-clock: thermal guard failed — leaving PowerMizer as-is"
    return 0
  fi
  local current
  current="$(gpuclock::_query_mode)"
  if ! gpuclock::_is_int "$current"; then
    log::warn "gpu-clock: could not read GPUPowerMizerMode — skipping"
    return 0
  fi
  state::save_once "$REAP_POWERMIZER_KEY" "$current"
  if [[ "$current" == "$REAP_POWERMIZER_MAX_PERF" ]]; then
    log::info "gpu-clock: PowerMizer already at max performance ($current)"
    return 0
  fi
  log::info "gpu-clock: setting GPUPowerMizerMode=$REAP_POWERMIZER_MAX_PERF (was $current)"
  if ! nvidia-settings -a "[gpu:0]/GPUPowerMizerMode=$REAP_POWERMIZER_MAX_PERF" >/dev/null 2>&1; then
    log::error "gpu-clock: failed to set GPUPowerMizerMode"
    return 0
  fi
  # RNF-02: verify the change actually took before reporting success.
  local after
  after="$(gpuclock::_query_mode)"
  if [[ "$after" == "$REAP_POWERMIZER_MAX_PERF" ]]; then
    log::info "gpu-clock: PowerMizer pinned to max performance (verified)"
  else
    log::error "gpu-clock: PowerMizer still '$after' after set — verification failed"
  fi
  return 0
}

gpuclock::revert() {
  if ! state::has "$REAP_POWERMIZER_KEY"; then
    log::info "gpu-clock: no saved PowerMizer mode — nothing to revert"
    return 0
  fi
  local saved
  saved="$(state::load "$REAP_POWERMIZER_KEY")"
  gpuclock::_is_int "$saved" || saved=0
  if ! gpuclock::_available; then
    log::warn "gpu-clock: nvidia-settings/X session unavailable — cannot restore PowerMizer (saved=$saved); state kept for a later retry"
    return 0
  fi
  log::info "gpu-clock: restoring GPUPowerMizerMode=$saved"
  if nvidia-settings -a "[gpu:0]/GPUPowerMizerMode=$saved" >/dev/null 2>&1; then
    state::clear "$REAP_POWERMIZER_KEY"
  else
    log::error "gpu-clock: failed to restore GPUPowerMizerMode=$saved"
  fi
  return 0
}

registry::register gpu-clock gpuclock::apply gpuclock::revert
