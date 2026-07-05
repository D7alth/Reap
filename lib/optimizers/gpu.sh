# shellcheck shell=bash
# gpu.sh — Optimus/PRIME GPU offload guidance (spec §7, §9 v1.5, RNF-04).
# The biggest potential FPS win on this hybrid-NVIDIA laptop is rendering the game
# on the dGPU instead of the Intel iGPU. reap does not launch the game (spec §4.3
# — the user launches it, e.g. via 'gamemoderun'), so this optimizer is advisory:
# it detects the offload setup and prints the exact command to render on the
# NVIDIA dGPU. It mutates no system state, so revert is a no-op (like gamemode) —
# reversibility (RNF-01) holds by construction and there is nothing to save.

# --- pure helpers (unit-tested; no hardware access) ---------------------------

# Map a `prime-select query` value to what reap should advise.
gpu::_classify_mode() {
  case "$1" in
    on-demand) printf 'offload' ;; # per-app offload works — the target setup
    nvidia) printf 'already' ;;    # dGPU already renders everything
    intel) printf 'blocked' ;;     # dGPU powered off — offload unavailable
    *) printf 'unknown' ;;         # prime-select absent / unrecognized value
  esac
}

# Build the command that launches the game on the dGPU, given what's installed.
gpu::_offload_command() {
  local has_prime_run="$1" has_gamemode="$2" launcher="<your-game>"
  ((has_gamemode)) && launcher="gamemoderun $launcher"
  if ((has_prime_run)); then
    printf 'prime-run %s' "$launcher"
  else
    printf '__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia %s' "$launcher"
  fi
}

# --- hardware probes (read-only, no sudo) -------------------------------------

gpu::_has_dgpu() {
  if command -v lspci >/dev/null 2>&1; then
    if lspci 2>/dev/null | grep -Ei '(vga|3d|display)' | grep -qi nvidia; then
      return 0
    fi
  fi
  command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1
}

gpu::_prime_mode() {
  command -v prime-select >/dev/null 2>&1 || {
    printf 'unknown'
    return 0
  }
  prime-select query 2>/dev/null || printf 'unknown'
}

gpu::_report_vram() {
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  local line used total
  line="$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1)" || return 0
  [[ -n "$line" ]] || return 0
  used="${line%%,*}"
  total="${line##*, }"
  used="${used// /}"
  total="${total// /}"
  [[ "$used" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] &&
    log::info "gpu: dGPU VRAM in use: ${used} MiB / ${total} MiB"
  return 0
}

# --- optimizer contract -------------------------------------------------------

gpu::apply() {
  if ! gpu::_has_dgpu; then
    log::info "gpu: no NVIDIA dGPU detected — offload not applicable"
    return 0
  fi

  local mode advice
  mode="$(gpu::_prime_mode)"
  advice="$(gpu::_classify_mode "$mode")"

  case "$advice" in
    already)
      log::info "gpu: PRIME profile is 'nvidia' — the dGPU already renders everything; no offload wrapper needed"
      ;;
    blocked)
      log::warn "gpu: PRIME profile is 'intel' — the NVIDIA dGPU is likely powered off; run 'sudo prime-select on-demand' and reboot to enable offload"
      ;;
    offload | unknown)
      # Under 'reap play' the launch is done by reap itself (gpu::launch), so the
      # copy-paste guidance would be redundant — just confirm the plan + VRAM.
      if [[ -n "${REAP_PLAY_ACTIVE:-}" ]]; then
        log::info "gpu: reap will launch the game on the dGPU (render offload)"
        gpu::_report_vram
      else
        local has_prime_run=0 has_gamemode=0 cmd
        command -v prime-run >/dev/null 2>&1 && has_prime_run=1
        gamemode::is_available && has_gamemode=1
        cmd="$(gpu::_offload_command "$has_prime_run" "$has_gamemode")"
        if [[ "$advice" == "unknown" ]]; then
          log::info "gpu: could not confirm PRIME mode (prime-select absent) — if your driver supports render offload, launch the game on the dGPU with:"
        else
          log::info "gpu: render offload available — launch the game on the dGPU with:"
        fi
        log::info "gpu:     $cmd"
        gpu::_report_vram
      fi
      ;;
  esac
  return 0
}

gpu::revert() { return 0; }

# --- launch (used by 'reap play' — spec-play.md) ------------------------------

# True if the game is runnable now (on PATH, or an executable path). Fail-fast so
# 'reap play' never stops services for a game it can't launch.
gpu::_resolve_game() { command -v "$1" >/dev/null 2>&1; }

# Pure argv builder (unit-tested): emits one token per line so callers can read it
# back into an array without a shell re-parse (no eval — args with spaces survive).
gpu::_launch_argv() {
  local has_prime_run="$1" has_gamemode="$2"
  shift 2
  local -a cmd=()
  if ((has_prime_run)); then
    cmd+=(prime-run)
  else
    cmd+=(env __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia)
  fi
  ((has_gamemode)) && cmd+=(gamemoderun)
  cmd+=("$@")
  printf '%s\n' "${cmd[@]}"
}

# Launch <game> [args…] on the dGPU and BLOCK until it exits; returns its code.
gpu::launch() {
  local has_prime_run=0 has_gamemode=0
  command -v prime-run >/dev/null 2>&1 && has_prime_run=1
  gamemode::is_available && has_gamemode=1
  local -a cmd=()
  mapfile -t cmd < <(gpu::_launch_argv "$has_prime_run" "$has_gamemode" "$@")
  log::info "gpu: launching on dGPU: ${cmd[*]}"
  "${cmd[@]}"
}

registry::register gpu gpu::apply gpu::revert
