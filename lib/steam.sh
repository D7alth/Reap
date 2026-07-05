# shellcheck shell=bash
# steam.sh — Steam appid targets for 'reap play' (spec-fps-fix.md §3.2).
# Steam/Proton games (e.g. ELDEN RING NIGHTREIGN, EAC) can't be exec'd directly:
# the launch goes through the Steam client (steam://rungameid/<appid>), which
# daemonizes — the game is never reap's child and its exit code is unobservable.
# So the session wait is process-tree based: any process whose cmdline references
# the game's install dir counts as "the game" (Proton's wrapper keeps the Unix
# path in its cmdline for the game's whole lifetime). We wait for it to appear
# (start timeout: Steam may need to boot, update, or run EAC setup first) and
# then to be gone.

: "${REAP_STEAM_START_TIMEOUT:=180}"
: "${REAP_STEAM_POLL_SECONDS:=5}"

# steam:<appid> or bare digits → appid on stdout; anything else fails.
steam::parse_target() {
  local target="${1:-}"
  if [[ "$target" =~ ^steam:([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    printf '%s' "$target"
    return 0
  fi
  return 1
}

# All "path" values from a libraryfolders.vdf.
steam::_vdf_paths() {
  sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$1" 2>/dev/null
}

# One "field" value from an appmanifest_<id>.acf.
steam::_manifest_field() {
  sed -n 's/^[[:space:]]*"'"$2"'"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$1" 2>/dev/null | head -1
}

# Steam library roots: the default installs plus extra libraries declared in
# their libraryfolders.vdf, deduped. Appending inside the for is safe: bash
# expands "${roots[@]}" once, so discovered libraries are not re-scanned.
steam::_library_roots() {
  local -a roots=()
  local root vdf path
  for root in "$HOME/.steam/steam" "$HOME/.local/share/Steam"; do
    [[ -d "$root" ]] && roots+=("$(readlink -f "$root")")
  done
  ((${#roots[@]})) || return 1
  for root in "${roots[@]}"; do
    vdf="$root/steamapps/libraryfolders.vdf"
    [[ -r "$vdf" ]] || continue
    while IFS= read -r path; do
      [[ -d "$path" ]] && roots+=("$(readlink -f "$path")")
    done < <(steam::_vdf_paths "$vdf")
  done
  printf '%s\n' "${roots[@]}" | awk '!seen[$0]++'
}

# Resolve an installed appid → sets REAP_STEAM_GAME_NAME and REAP_STEAM_GAME_DIR
# (absolute install path, the process-match key). Fails if not installed.
steam::resolve() {
  local appid="$1" root manifest name installdir
  while IFS= read -r root; do
    manifest="$root/steamapps/appmanifest_${appid}.acf"
    [[ -r "$manifest" ]] || continue
    installdir="$(steam::_manifest_field "$manifest" installdir)"
    [[ -n "$installdir" && -d "$root/steamapps/common/$installdir" ]] || continue
    name="$(steam::_manifest_field "$manifest" name)"
    REAP_STEAM_GAME_NAME="${name:-appid $appid}"
    REAP_STEAM_GAME_DIR="$root/steamapps/common/$installdir"
    return 0
  done < <(steam::_library_roots)
  return 1
}

steam::_game_pids() {
  local escaped
  escaped="$(app::_regex_escape "$REAP_STEAM_GAME_DIR")"
  pgrep -f -- "$escaped" 2>/dev/null || true
}

# Launch <appid> via the Steam client and BLOCK until the game's process tree is
# gone. Returns 1 if the game never appears within the start timeout (Steam not
# logged in, update dialog, launch cancelled) so the caller restores and exits.
steam::launch_and_wait() {
  local appid="$1"
  log::info "steam: launching '$REAP_STEAM_GAME_NAME' (appid $appid) via Steam"
  log::info "steam: GPU/offload env can't be injected here — keep it in the game's Steam Launch Options"
  # If the client isn't running, 'steam' becomes the client and never returns —
  # always detach it.
  nohup steam "steam://rungameid/${appid}" >/dev/null 2>&1 &

  local waited=0
  while [[ -z "$(steam::_game_pids)" ]]; do
    if ((waited >= REAP_STEAM_START_TIMEOUT)); then
      log::error "steam: no game process after ${REAP_STEAM_START_TIMEOUT}s — giving up (is Steam logged in? update pending?)"
      return 1
    fi
    sleep 2
    ((waited += 2))
  done
  log::info "steam: game process detected (~${waited}s) — session active until it exits"

  while [[ -n "$(steam::_game_pids)" ]]; do
    sleep "$REAP_STEAM_POLL_SECONDS"
  done
  log::info "steam: game process tree gone — session over (game exit code is not observable via Steam)"
  return 0
}
