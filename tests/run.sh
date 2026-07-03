#!/usr/bin/env bash
set -uo pipefail
# Dependency-free tests for the pure/root-free logic (denylist, state).
# Privileged paths (services, sysfs, PPD) are exercised manually — see README.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TESTS_DIR/../lib" && pwd)"

export REAP_STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$REAP_STATE_DIR"' EXIT

# shellcheck source=/dev/null
source "$LIB_DIR/log.sh" >/dev/null
# shellcheck source=/dev/null
source "$LIB_DIR/state.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/denylist.sh"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
no() {
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n' "$1"
}

assert_true() { if "$@" >/dev/null 2>&1; then ok "$*"; else no "$*"; fi; }
assert_false() { if "$@" >/dev/null 2>&1; then no "NOT($*)"; else ok "NOT($*)"; fi; }
assert_eq() {
  if [[ "$1" == "$2" ]]; then ok "$3"; else
    no "$3 (expected '$2', got '$1')"
  fi
}

echo "denylist (RC-01/02/03):"
assert_true svc::is_protected bluetooth
assert_true svc::is_protected thermald
assert_true svc::is_protected NetworkManager
assert_true svc::is_protected systemd-resolved
assert_true svc::is_protected bluetooth.service
assert_true svc::is_protected power-profiles-daemon
assert_false svc::is_protected ollama
assert_false svc::is_protected postgresql@18-main
assert_false svc::is_protected snapd

echo "state idempotency (RNF-03):"
state::save_once vm-swappiness 60 >/dev/null
state::save_once vm-swappiness 10 >/dev/null # must NOT overwrite the original
assert_eq "$(state::load vm-swappiness)" "60" "save_once keeps first value"
assert_true state::has vm-swappiness
state::clear vm-swappiness
assert_false state::has vm-swappiness

echo
echo "passed: $PASS  failed: $FAIL"
((FAIL == 0))
