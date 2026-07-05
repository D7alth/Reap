# reap

**Objective:** Play Elden Ring Nightreaim on a GTX 1050 laptop.

This project started as a practical need: an old notebook with 16GB RAM and a GTX 1050 wasn't cutting it for Elden Ring's DLC. Rather than accept lower framerates, the approach was to systematically identify and remove non-essential system load — background services consuming VRAM, I/O-heavy daemons, and underutilized processes. What began as a quick bash script evolved into a structured, reversible resource optimizer.

`reap` stops non-essential services, applies kernel optimizations (VM tuning, CPU governor), and restores everything when you're done. Built for Ubuntu + GNOME. This is the **V1 core**.

## Usage

```
reap gaming        # stop non-essential services/apps + apply optimizations
reap play <game>   # gaming + launch <game> on the dGPU + auto-restore when it exits
reap exit          # restore exactly what 'gaming' changed (no-op if no saved state)
reap status        # show if gaming mode is active, what changed, and recent runs
reap help
```

Apps are **not** reopened automatically — relaunch them yourself after `exit`.

`reap play <game> [args…]` runs a whole session in one command: it does everything
`gaming` does, launches the game on the NVIDIA dGPU (via `prime-run` + `gamemoderun`
when present), blocks until the game exits, then restores everything — automatically,
even on a crash or Ctrl-C. It refuses to start if a `gaming` session is already
active (run `reap exit` first). See [.claude/spec-play.md](.claude/spec-play.md).

## Status & logs

`reap status` is read-only (no sudo) and reports whether gaming mode is active,
which services/kernel values reap changed, the live kernel state, and a summary of
recent executions:

```
$ reap status
reap — status

gaming mode active: yes

changed by reap (restored on exit):
  services stopped:
    - ollama
    - snapd
  vm.swappiness (original): 60
  power profile (original): balanced
...
recent executions (last 10):
  20260703T120000-111    gaming  2026-07-03T12:00:00-0300  ok
  20260703T130000-222    exit    2026-07-03T13:00:00-0300  warnings
```

Each `gaming`/`exit` run is journaled as structured JSONL in
`${XDG_STATE_HOME:-$HOME/.local/state}/reap/executions.jsonl`, retained for the
**last 10 executions**. See [.claude/spec-observability.md](.claude/spec-observability.md)
for the format and known limitations.

## Install

`reap` is **not installed by anything** — cloning the repo does not put it on your
`PATH`. Until you install it, run it in place with `./bin/reap gaming`.

The `bin/reap` script must keep `lib/` beside it, so **do not copy just the
script** — symlink it or add the repo's `bin/` to your `PATH`.

**Option A — symlink into `~/.local/bin`** (per-user, no sudo; make sure that dir
is on your `PATH`):

```bash
git clone <repo-url> ~/.local/share/reap
ln -s ~/.local/share/reap/bin/reap ~/.local/bin/reap
reap help    # verify
```

**Option B — add the repo's `bin/` to your `PATH`** (edit `~/.bashrc`):

```bash
echo 'export PATH="$HOME/path/to/reap/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
reap help
```

**Option C — system-wide symlink** (all users, needs sudo):

```bash
sudo ln -s /opt/reap/bin/reap /usr/local/bin/reap
```

To uninstall, remove the symlink (or the `PATH` line) — `reap` writes only to
`~/.local/state/reap/`, which you can delete too.

### Requirements

- `bash`, `systemctl`, `flock`, `sudo` (standard on Ubuntu).
- Optional: [Feral GameMode](https://github.com/FeralInteractive/gamemode)
  (`gamemoderun`) — if present, CPU/IO tuning is delegated to it; otherwise reap
  falls back to `powerprofilesctl` + `vm.swappiness`.

## How it works

- **Services** (`lib/services.sh`, Appendix A of the spec): a fixed set of
  non-essential units (`ollama`, `postgresql@18-main`, `snapd`, …) is stopped and
  the originally-active ones are recorded for restore.
- **Denylist** (`lib/denylist.sh`): `bluetooth`, `thermald`, `NetworkManager`,
  every `systemd-*`, and other critical units can **never** be stopped — absolute
  priority over the target set.
- **Apps** (`lib/apps.sh`): IDEs/browsers get SIGTERM + an 8 s grace period.
  SIGKILL is off by default (`REAP_ALLOW_SIGKILL=1` to enable) and never sent to
  apps flagged sensitive.
- **Optimizers** (`lib/optimizers/`): registered via a small registry so new ones
  drop in without touching the core.
  - `gamemode` — if Feral GameMode is installed, CPU/IO/priority tuning is
    delegated to it (launch your game with `gamemoderun <game>`).
  - `cpu` / `vm` — manual fallback only when GameMode is absent: PPD-aware
    `performance` profile and `vm.swappiness=10`, behind a thermal guard.
  - `thermal` — forced performance requires `thermald` active **and** temperature
    below 85 °C, otherwise CPU tuning stands down.
  - `gpu` — on this hybrid-NVIDIA (Optimus) laptop, detects the dGPU + PRIME mode
    and prints the exact command to render the game on the NVIDIA dGPU
    (`prime-run gamemoderun <game>`, or the `__NV_PRIME_RENDER_OFFLOAD` env method).
    Advisory only — reap doesn't launch the game, so it changes no system state and
    has nothing to revert. See [.claude/spec-gpu-offload.md](.claude/spec-gpu-offload.md).

State lives in `${XDG_STATE_HOME:-$HOME/.local/state}/reap/`. A `flock` prevents
two concurrent runs from corrupting it, and backups are never overwritten
(running `gaming` twice is safe).

## Layout

```
bin/reap                 entry point (sources lib, dispatches)
lib/core.sh              dispatch, lock, gaming/exit
lib/log.sh               console logging + notify (mirrors to journal)
lib/journal.sh           persistent JSONL execution log (last 10 runs)
lib/status.sh            reap status (read-only report)
lib/play.sh              reap play (session orchestrator: gaming + launch + restore)
lib/state.sh             save/restore with idempotency guard
lib/privilege.sh         sudo preflight + verified execution
lib/services.sh          service target set + stop/restore
lib/denylist.sh          non-editable protection list
lib/apps.sh              graceful app shutdown
lib/registry.sh          optimizer registry
lib/optimizers/*.sh      gamemode, cpu, vm, thermal, gpu
tests/run.sh             root-free tests (denylist, state, journal)
```

## Tests

```
tests/run.sh
```

Covers the logic that needs no root (denylist protection, state idempotency).
Privileged paths (service stop/verify, sysfs/PPD, thermal guard) are validated by
running `reap gaming` → `reap exit` on the target machine.
