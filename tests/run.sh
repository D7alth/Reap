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
# shellcheck source=/dev/null
source "$LIB_DIR/journal.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/registry.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/optimizers/gpu.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/optimizers/gpu-clock.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/apps.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/steam.sh"

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

echo "journal json escaping:"
assert_eq "$(journal::_json_escape 'a"b\c')" 'a\"b\\c' "escapes quote and backslash"

echo "journal retention — last 10 executions (spec v1.1):"
export REAP_LOG_FILE="$REAP_STATE_DIR/exec.jsonl"
: >"$REAP_LOG_FILE"
for i in $(seq 1 12); do
  REAP_SESSION_ID="sess-$(printf '%02d' "$i")"
  REAP_SESSION_CMD="gaming"
  journal::append info "entry for session $i"
done
journal::prune 10
distinct="$(grep -o '"session":"[^"]*"' "$REAP_LOG_FILE" | sort -u | wc -l | tr -d ' ')"
assert_eq "$distinct" "10" "retention keeps exactly 10 sessions"
if grep -q '"session":"sess-01"' "$REAP_LOG_FILE"; then no "oldest session dropped"; else ok "oldest session (sess-01) dropped"; fi
if grep -q '"session":"sess-12"' "$REAP_LOG_FILE"; then ok "newest session (sess-12) kept"; else no "newest session kept"; fi
unset REAP_SESSION_ID REAP_SESSION_CMD REAP_LOG_FILE

echo "gpu offload classification (spec v1.5):"
assert_eq "$(gpu::_classify_mode on-demand)" "offload" "on-demand => offload"
assert_eq "$(gpu::_classify_mode nvidia)" "already" "nvidia => already (dGPU renders all)"
assert_eq "$(gpu::_classify_mode intel)" "blocked" "intel => blocked (dGPU off)"
assert_eq "$(gpu::_classify_mode wat)" "unknown" "unrecognized => unknown"

echo "gpu offload launch command:"
assert_eq "$(gpu::_offload_command 1 1)" "prime-run gamemoderun <your-game>" "prime-run + gamemode"
assert_eq "$(gpu::_offload_command 1 0)" "prime-run <your-game>" "prime-run only"
assert_eq "$(gpu::_offload_command 0 1)" "__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia gamemoderun <your-game>" "env fallback + gamemode"
assert_eq "$(gpu::_offload_command 0 0)" "__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <your-game>" "env fallback only"

echo "gpu launch argv (spec-play.md):"
argv() { gpu::_launch_argv "$@" | tr '\n' '|'; }
assert_eq "$(argv 1 1 eldenring)" "prime-run|gamemoderun|eldenring|" "prime-run + gamemode + game"
assert_eq "$(argv 1 0 eldenring)" "prime-run|eldenring|" "prime-run, no gamemode"
assert_eq "$(argv 0 1 eldenring)" "env|__NV_PRIME_RENDER_OFFLOAD=1|__GLX_VENDOR_LIBRARY_NAME=nvidia|gamemoderun|eldenring|" "env fallback + gamemode"
assert_eq "$(argv 1 1 eldenring --windowed)" "prime-run|gamemoderun|eldenring|--windowed|" "game args are preserved"
assert_eq "$(argv 1 1 'my game' -x)" "prime-run|gamemoderun|my game|-x|" "arg with space stays one token"

echo "gpu game resolution (fail-fast, spec-play.md):"
assert_true gpu::_resolve_game sh
assert_false gpu::_resolve_game reap-definitely-not-a-real-binary-xyz

echo "gpu-clock PowerMizer helpers (spec-fps-fix.md):"
assert_true gpuclock::_is_int 0
assert_true gpuclock::_is_int 2
assert_false gpuclock::_is_int adaptive
assert_false gpuclock::_is_int ""
state::save_once gpu-powermizer 0 >/dev/null
state::save_once gpu-powermizer 1 >/dev/null # must NOT overwrite the original
assert_eq "$(state::load gpu-powermizer)" "0" "save_once keeps original PowerMizer mode"
state::clear gpu-powermizer
assert_false state::has gpu-powermizer

echo "steam target parsing (spec-fps-fix.md §3.2):"
assert_eq "$(steam::parse_target steam:2622380)" "2622380" "steam:<appid> form"
assert_eq "$(steam::parse_target 945360)" "945360" "bare digits form"
assert_false steam::parse_target eldenring
assert_false steam::parse_target steam:
assert_false steam::parse_target steam:12ab
assert_false steam::parse_target ""

echo "steam manifest/vdf parsing:"
FAKE_LIB="$REAP_STATE_DIR/fakelib"
mkdir -p "$FAKE_LIB/steamapps/common/Fake Game"
cat >"$FAKE_LIB/steamapps/appmanifest_111.acf" <<'ACF'
"AppState"
{
	"appid"		"111"
	"name"		"Fake Game"
	"installdir"		"Fake Game"
}
ACF
assert_eq "$(steam::_manifest_field "$FAKE_LIB/steamapps/appmanifest_111.acf" name)" "Fake Game" "manifest name"
assert_eq "$(steam::_manifest_field "$FAKE_LIB/steamapps/appmanifest_111.acf" installdir)" "Fake Game" "manifest installdir"
cat >"$FAKE_LIB/steamapps/libraryfolders.vdf" <<VDF
"libraryfolders"
{
	"0"
	{
		"path"		"$FAKE_LIB"
	}
}
VDF
assert_eq "$(steam::_vdf_paths "$FAKE_LIB/steamapps/libraryfolders.vdf")" "$FAKE_LIB" "vdf path extraction"

echo "steam appid resolution (mocked library roots):"
steam::_library_roots() { printf '%s\n' "$FAKE_LIB"; } # mock the fs-discovery border
assert_true steam::resolve 111
assert_eq "$REAP_STEAM_GAME_NAME" "Fake Game" "resolve sets game name"
assert_eq "$REAP_STEAM_GAME_DIR" "$FAKE_LIB/steamapps/common/Fake Game" "resolve sets game dir"
assert_false steam::resolve 999

echo
echo "passed: $PASS  failed: $FAIL"
((FAIL == 0))
