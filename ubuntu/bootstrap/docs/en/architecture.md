# Architecture

## Layout

```
ubuntu/bootstrap/
├── ubuntu-bootstrap          entry point: global options, loading lib/, command dispatch
├── install.sh                install / update / rollback / uninstall (safe for curl | bash)
├── VERSION                   version (checked against the release tag in CI)
├── lib/
│   ├── core.sh               output and log, exit codes, temp files, atomic writes, KEY=VALUE, lists
│   ├── validate.sh           is_* predicates for every input
│   ├── paths.sh              state paths; UBB_SYSROOT moves them into a test sandbox
│   ├── facts.sh              system facts F_*, sshd -T as the source of truth, users, "planned facts"
│   ├── pkg.sh                apt with lock waiting, deb822 repositories with fingerprint checks, snap
│   ├── svc.sh                systemd units, drop-ins, sshd reconfiguration aware of socket activation
│   ├── tx.sh                 transactions: journal, backups, file_write/undo, rollback, rollback timer, module state
│   ├── options.sh            option declaration (opt), configuration assembly and validation, profiles, saving
│   ├── modules.sh            module registry, dependencies, topological sort
│   ├── runner.sh             apply loop, guards, confirmation of risky changes
│   ├── ui.sh                 dialogue: terminal / --yes / no terminal, confirmations, countdown
│   └── audit.sh              check accumulator for audit and doctor
├── commands/<cmd>.sh         one command per file
├── modules/<module>.sh       one module per file
├── profiles/*.conf           module sets and option values
├── systemd/                  ubuntu-bootstrap-recover.service
├── completion/               bash completion
├── examples/                 web.conf, docker-host.conf, cloud-init.yaml, ansible.yml
├── docs/ru, docs/en          documentation
└── tests/                    run.sh, lib.sh, unit.sh, e2e.sh, coverage-merge.py, docker/Dockerfile
```

A command is a file `commands/<name>.sh` with the variables `CMD_SUMMARY`, `CMD_GROUP` (setup/run/inspect/maintenance), `CMD_ROOT` (1 by default) and the functions `cmd_usage`, `cmd_run`. A module is a file `modules/<name>.sh` (contract in [Extending](extending.md)). New files are picked up automatically: the entry point lists the directories, no registration is needed.

## Entry point

1. `set -Eeuo pipefail`, `shopt -s lastpipe` (the last pipeline command runs in the current shell, so `render | file_write` sets `FILE_CHANGED`), `umask 022`, `LC_COLLATE=C`.
2. Libraries are loaded in a fixed order: core, validate, paths, facts, pkg, svc, tx, options, modules, ui, audit, runner.
3. Traps: `EXIT` → `on_exit` (exit hooks, temp directory cleanup), `INT`/`TERM` → exit 130, `HUP` → `ui_on_hangup` (continue without a terminal), `ERR` → `on_err` (message with file and line; a deliberate `return N` is not a failure).
4. `parse_global_args` parses options up to the first command word; `ui_init` decides whether the run is interactive (stdin is a terminal or `/dev/tty` is usable; `--yes` turns it off).
5. The command file is loaded; with `CMD_ROOT=1` and no root the run is refused (with `--dry-run` only a warning).
6. `facts_load`, `modules_discover`, then `cmd_run` with the remaining arguments.

## The `apply` flow

1. `config_load`: profile (from `--profile` or `PROFILE=` in the file) → configuration file → `--set`; every pair is validated by its option type, unknown keys and bad values are errors that name their source.
2. `runner_select` → `modules_selected`: modules from `--only` or the config (`MODULES` / default set + `MODULES_ADD` − `MODULES_SKIP`), transitive `MOD_DEPS`, minus `--skip`, plus `preflight` first. Sorting is Kahn's algorithm over the `MOD_DEPS` and `MOD_AFTER` edges among the selected modules; ties go to the canonical order `MOD_CANON`, unknown modules follow it alphabetically; a cycle is an error.
3. With `pending.env` present: code 5.
4. `tx_begin`: lock, run directory, journal, backup directory, log, `run.env` with status `running`, a journald event, registration of the `tx_on_exit` hook (marks an unfinished run `interrupted`).
5. For every module:
   - `module_load` (resets the `mod_*` stubs, sources the file);
   - skip when `MOD_CONTAINER=0` inside a container;
   - skip when the state is `applied`, the option hash matches and `mod_check` passes (except `MOD_ALWAYS=1` and `--reapply`);
   - `tx_module_begin` (record `M`), `mod_apply`;
   - code 0 → `mod_verify` → `runner_mark_applied` (STATUS, CONFIG_HASH, APPLIED_AT, RUN_ID, VERSION); a failed verify rolls the module back like an error;
   - code 3 (`E_REFUSED`) → rollback of the module's records (usually none: guards fire before changes), state `refused`, stop (or continue with `--keep-going`);
   - code 4 (`E_ROLLED_BACK`) → the module already rolled itself back (timer/refusal), stop;
   - any other code → `runner_fail`: disarm a pending timer of this module, roll back its journal records, state `failed`, stop.
6. `runner_finish`: run status (`done`/`failed`/`refused`/`rolled_back`), summary (applied, skipped, rolled back, refused, files, warnings, pending confirmation, backup and log paths), reboot reminder; the exit code is the first non-zero of error/refusal/rollback.

`plan` is the same flow with `DRY_RUN=1`. `wizard` first assembles the configuration in a dialogue, saves it, then runs the same flow in dry-run (in a subshell) and, after consent, for real.

## Facts (`lib/facts.sh`)

Collected once, read-only: OS and codename from `/etc/os-release`, architecture, kernel, systemd presence, virtualization and the container flag (`systemd-detect-virt -c`, `/.dockerenv`, `/run/.containerenv`), memory, swap, CPUs, free space, root filesystem type, default-route interface and IP, hostname, `reboot-required`, the current SSH session (from `SSH_CONNECTION`; `sudo` drops the variable, so the client address falls back to `who -m`), sshd ports from `sshd -T`.

`sshd -T` is the source of truth for the effective sshd configuration (it honours every `Include` and directive order). With socket activation `/run/sshd` may not exist before the first connection — it is created before the call.

"Planned facts" (`plan_mark user:deploy`, `keys:deploy`, `sudo:deploy`) are recorded by modules only in dry-run; `user_exists`, `user_has_keys`, `user_sudo_usable` and `human_users` take them into account, so the ssh guards in a plan see the user that users will create earlier in the same run.

## Options and configuration (`lib/options.sh`)

`opt NAME TYPE DEFAULT HELP [adv]` registers an option with its type, default, help text, owning module and the "advanced" flag. Options of every module are loaded during `modules_discover`, so config validation knows the whole vocabulary and `modules --options` prints all of it. `cfg NAME` returns the effective value (`CONF` or the default); `cfg_bool` and `cfg_list` are convenience wrappers. A module's configuration hash is the SHA256 of the `NAME=value` pairs of all its options; it is stored on apply and compared on the next run.

`KEY=VALUE` files are read by `kv_load` (never `source`d): the line shape and key name are validated, values are taken verbatim. `kv_set` preserves the key order of the file.

## Transactions (`lib/tx.sh`)

| Function | Purpose |
|---|---|
| `tx_begin CMD` | lock, directories, journal, log, `run.env`, exit hook |
| `file_write PATH [MODE] [OWNER]` | stdin → file: content comparison, backup, `W` record, atomic replace; `FILE_CHANGED=1` on change; a diff in dry-run |
| `file_remove PATH` | backup, `D` record, removal |
| `file_snapshot PATH` | copy of a file an external command (ufw, certbot) is about to change |
| `file_set_block PATH MARKER [MODE]` | replace the block between markers inside a foreign file; empty stdin removes the block |
| `undo CMD...` | record an undo command (`U`) — before the change it reverts |
| `run CMD...` | execute with logging; on failure the last output lines are shown; dry-run only prints; the child ignores `SIGHUP` |
| `tx_rollback_journal JOURNAL [MODULE]` | reverse replay: restore files, remove created ones, run undo commands; the module is loaded so an undo command can be one of its functions |
| `pending_arm/disarm/confirm/rollback` | the rollback timer and `pending.env` |
| `module_state_set/get` | `/var/lib/ubuntu-bootstrap/modules/<m>.env` |

## Execution and confirmations (`lib/runner.sh`, `lib/ui.sh`)

- `guard_refuse MSG`: a guard; with `--force` a warning and continue, otherwise an error and code 3.
- `confirm_danger MSG`: a dangerous action; on a terminal the word `yes`, `--yes` accepts, without a terminal a refusal; in dry-run a note.
- `confirm_or_rollback MODULE TIMEOUT MODE QUESTION SELFCHECK`: arm the timer, wait for an answer / run the self-check / return (`wait` mode), then `pending_confirm` or `pending_rollback` with code 4.
- `wait_confirmation`: a countdown; every 5 seconds it checks whether `pending.env` was removed externally (`confirm` from another session or the timer firing).

Interactivity is determined once: stdin is a terminal, or `/dev/tty` can be opened (this is how the wizard works through `curl | bash`). All questions go through `ask_yn`, `ask_input` (with a validator and retry), `ask_choice`, `ask_secret` (no echo, not logged). Without a terminal every question gets its safe default and is logged.

## On-disk state

```
/etc/ubuntu-bootstrap/bootstrap.conf        configuration (600)
/etc/ubuntu-bootstrap/modules.d/*.sh        custom modules
/etc/ubuntu-bootstrap/profiles.d/*.conf     custom profiles
/var/lib/ubuntu-bootstrap/.lock             flock lock
/var/lib/ubuntu-bootstrap/pending.env       pending confirmation (RUN_ID, MODULE, DEADLINE, MECH, TIMER, DESC)
/var/lib/ubuntu-bootstrap/runs/<RUN_ID>/run.env     STATUS, COMMAND, VERSION, STARTED_AT, DRY_RUN, USER, FINISHED_AT
/var/lib/ubuntu-bootstrap/runs/<RUN_ID>/journal     M/W/D/U records
/var/lib/ubuntu-bootstrap/modules/<m>.env   STATUS, CONFIG_HASH, APPLIED_AT, RUN_ID, VERSION, CONFIRMED_AT, ROLLED_BACK_AT
/var/backups/ubuntu-bootstrap/<RUN_ID>/     file copies under their absolute paths
/var/log/ubuntu-bootstrap/<RUN_ID>.log      run log
/opt/ubuntu-bootstrap/.install              REPO, REF, COMMIT, INSTALLED_AT
```

Environment variables: `UBB_SYSROOT` (tests: prefix of every state path), `UBB_MODULE_PATH` (additional module directory), `UBB_OS_RELEASE` (tests), `NO_COLOR`; for the installer `UBB_REPO`, `UBB_REF`, `UBB_SIGNING_KEY_FPR`, `GITHUB_TOKEN`.

## Decisions and their sources

| Decision | Rationale |
|---|---|
| sshd is configured through `sshd_config.d/00-…` | sshd applies the first value of a directive; `Include` sits at the top of `sshd_config`, so `00-` beats both cloud-init and the main file — `sshd_config(5)` |
| Port change via `daemon-reload` + `restart ssh.socket` | on Ubuntu 22.10+ sshd is socket-activated and the generator reads the ports; `reload` does not change the port — [LP#2069041](https://bugs.launchpad.net/ubuntu/+source/openssh/+bug/2069041). Sessions survive the restart: `KillMode=process` |
| `sshd -T` rather than file parsing | honours every included file and `Match` block; `without-password` is normalized to `prohibit-password` |
| `PermitRootLogin no` only with an administrator holding a key and working sudo | otherwise the server has no administrative access left; `adduser --disabled-password` yields a user whose sudo does not work |
| Rollback timer outside the session (`systemd-run`) and a recover service | a dropped session, a hung terminal or a reboot must not leave the server in an unconfirmed state; the recover unit has no `Before=ssh.socket` to avoid a systemd job cycle |
| Docker: deb822, key in `/etc/apt/keyrings`, fingerprint check, removal of conflicting packages | [docs.docker.com/engine/install/ubuntu](https://docs.docker.com/engine/install/ubuntu/) |
| Container protection in `DOCKER-USER` | "Docker and ufw are incompatible"; Docker writes its rules into FORWARD/nat, bypassing INPUT; `DOCKER-USER` is evaluated first and never flushed by Docker — [Packet filtering and firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/). `iptables-restore` on `ufw reload` reinstalls the declared chain |
| nginx.org: fingerprint membership, pinning 900 | the key file holds several keys; [nginx.org/en/linux_packages.html](https://nginx.org/en/linux_packages.html) |
| fail2ban `backend=systemd` with an explicit `journalmatch` | `auth.log` may be absent on 24.04+; OpenSSH 9.8+ logs from `sshd-session`; `python3-systemd` is only Recommends on 22.04 |
| unattended-upgrades: security pocket, no automatic reboot | [Ubuntu Server Guide: Automatic updates](https://ubuntu.com/server/docs/how-to/software/automatic-updates/) |
| Time: chrony on 26.04, timesyncd on older releases | Ubuntu 26.04 ships chrony with NTS; both units carry `ConditionVirtualization=!container` |
| sysctl per CIS Ubuntu Benchmark L1; `ip_forward` kept with Docker/WireGuard | otherwise Docker and the VPN stop routing |
| nginx TLS per the Mozilla intermediate profile | [ssl-config.mozilla.org](https://ssl-config.mozilla.org/) |
| GitHub user keys and GitHub host keys over TLS | `github.com/<user>.keys`, `api.github.com/meta` — GitHub docs "SSH key fingerprints" |
| `ufw` files ASCII only | ufw rewrites its files in ASCII and fails on non-ASCII comments |
| `KEY=VALUE` files are never executed | a config file, even with mode 600, must not be a code execution vector |
