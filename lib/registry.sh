# shellcheck shell=bash
# registry.sh — optimizer registry (spec §4.2, RNF-04).
# Each optimizer registers an apply/revert pair on source. 'gaming'/'exit' only
# call apply_all/revert_all, so adding a future optimizer (e.g. GPU offload)
# never touches the core. revert runs in reverse registration order.

REAP_REG_NAMES=()
REAP_REG_APPLY=()
REAP_REG_REVERT=()

registry::register() {
  REAP_REG_NAMES+=("$1")
  REAP_REG_APPLY+=("$2")
  REAP_REG_REVERT+=("$3")
}

registry::apply_all() {
  local i
  ((${#REAP_REG_NAMES[@]} == 0)) && return 0
  for i in "${!REAP_REG_NAMES[@]}"; do
    log::info "optimizer '${REAP_REG_NAMES[$i]}': apply"
    if ! "${REAP_REG_APPLY[$i]}"; then
      log::warn "optimizer '${REAP_REG_NAMES[$i]}' apply reported failure"
    fi
  done
  return 0
}

registry::revert_all() {
  local i
  ((${#REAP_REG_NAMES[@]} == 0)) && return 0
  for ((i = ${#REAP_REG_NAMES[@]} - 1; i >= 0; i--)); do
    log::info "optimizer '${REAP_REG_NAMES[$i]}': revert"
    if ! "${REAP_REG_REVERT[$i]}"; then
      log::warn "optimizer '${REAP_REG_NAMES[$i]}' revert reported failure"
    fi
  done
  return 0
}
