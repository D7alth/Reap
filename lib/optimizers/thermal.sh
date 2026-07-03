# shellcheck shell=bash
# thermal.sh — thermal guard for forced CPU performance (RNF-05, bug B8).
# Forced performance is only allowed when thermald is active AND the current
# temperature is below the threshold. Otherwise the CPU optimizer stands down
# (it does not block the rest of the session).

readonly REAP_THERMAL_THRESHOLD_C=85

thermal::_max_temp_c() {
  local zone temp max=0
  for zone in /sys/class/thermal/thermal_zone*/temp; do
    [[ -r "$zone" ]] || continue
    temp="$(cat "$zone" 2>/dev/null)" || continue
    [[ "$temp" =~ ^[0-9]+$ ]] || continue
    ((temp > max)) && max="$temp"
  done
  printf '%s' "$((max / 1000))"
}

thermal::guard() {
  if ! systemctl is-active --quiet thermald 2>/dev/null; then
    log::warn "thermald not active — refusing to sustain forced performance (RNF-05)"
    return 1
  fi
  local temp
  temp="$(thermal::_max_temp_c)"
  if ((temp >= REAP_THERMAL_THRESHOLD_C)); then
    log::warn "CPU at ${temp}C (>= ${REAP_THERMAL_THRESHOLD_C}C) — skipping forced performance (B8)"
    return 1
  fi
  log::info "thermal guard OK (${temp}C, thermald active)"
  return 0
}
