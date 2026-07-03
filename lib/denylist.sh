# shellcheck shell=bash
# denylist.sh — hardcoded, non-editable protection list (spec §5, RC-01/02/03).
# svc::is_protected has absolute priority: a service here is NEVER stopped,
# even if a future edit adds it to the target set by mistake.

readonly REAP_DENYLIST=(
  bluetooth               # RC-01: user's controller is Bluetooth
  thermald                # RC-03: thermal throttling safety
  NetworkManager
  wpa_supplicant
  dbus
  polkit
  rtkit-daemon            # realtime audio scheduling
  systemd-oomd
  systemd-logind
  gdm
  nvidia-persistenced     # lowers GPU init latency
  power-profiles-daemon   # managed by the CPU optimizer, never stopped
  udisks2
  systemd-udevd
  systemd-journald
)

svc::is_protected() {
  local name="${1%.service}" entry
  # Every systemd-* unit is critical infrastructure.
  [[ "$name" == systemd-* ]] && return 0
  for entry in "${REAP_DENYLIST[@]}"; do
    [[ "$name" == "$entry" ]] && return 0
  done
  return 1
}
