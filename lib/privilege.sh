# shellcheck shell=bash
# privilege.sh — sudo preflight + verified execution (RNF-02).
# No '|| true' anywhere: every privileged call reports failure instead of
# masking it as success (bug B4).

sudo::preflight() {
  if ! sudo -v; then
    log::error "sudo authentication failed — aborting, no changes made"
    return 1
  fi
  return 0
}

sudo::run() {
  if ! sudo "$@"; then
    log::error "privileged command failed: sudo $*"
    return 1
  fi
  return 0
}
