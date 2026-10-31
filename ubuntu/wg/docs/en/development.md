# Development

How the code is organized, how to add a command, and how the project is tested.

- [Layout](#layout)
- [Conventions](#conventions)
- [Adding a command](#adding-a-command)
- [Tests](#tests)
- [Coverage](#coverage)
- [Continuous integration](#continuous-integration)
- [Releasing](#releasing)

## Layout

```
ubuntu/wg/
├── wg-network            entry point: global options, command lookup, dry-run sandbox
├── install.sh            install, update, rollback, uninstall
├── VERSION
├── lib/
│   ├── core.sh           output, exit codes, confirmations, atomic writes, KEY=VALUE files
│   ├── validate.sh       is_* predicates for every kind of input
│   ├── ip.sh             IPv4/IPv6 arithmetic: CIDR, containment, overlap, RFC 5952
│   ├── config.sh         paths, settings, interface selection
│   ├── state.sh          desired state, validation, lock, snapshots, transactions
│   ├── render.sh         config and firewall hook rendering, canonical config form
│   ├── apply.sh          plans, apply classes, confirmation, rollback
│   ├── guard.sh          SSH, foreign VPN and network guards
│   ├── system.sh         packages, systemd, routes, firewall, SSH sessions, fast reconnect
│   ├── node.sh           invitation tokens, client configs, peer-node initialization
│   ├── runtime.sh        kernel view (wg show dump), peer states, outcome texts
│   └── migrate.sh        migration of legacy state
├── commands/             one file per command ("peer add" -> peer-add.sh)
├── systemd/              wg-network-reresolve.{service,timer}
├── completion/           bash completion
├── docs/                 this documentation (en, ru)
└── tests/
    ├── run.sh            lint | unit | e2e | systemd | distro | coverage | all
    ├── lib.sh            a tiny assertion library
    ├── unit.sh           pure logic
    ├── e2e.sh            real WireGuard in network namespaces
    ├── systemd.sh        real systemd and OpenSSH in containers
    ├── stubs/            systemctl, systemd-run, logger, timedatectl for e2e
    ├── stubs-fw/         ufw, firewall-cmd for e2e
    ├── docker/           image of a node with systemd as PID 1
    └── coverage/         BASH_ENV tracer and report.py
```

## Conventions

- Bash 4.4+, `set -Eeuo pipefail`, `umask 077`, locale-independent sorting (`LC_COLLATE=C`).
- Every library is sourced by the entry point; commands never source anything themselves.
- Messages go to stderr through `log_info`, `log_ok`, `log_warn`, `log_error`; stdout is for data only.
- Errors end with `die` (exit 1), `die_usage` (exit 2) or `die_code CODE`. Exit codes are a public contract: see `lib/core.sh` and [Exit codes](commands.md#exit-codes).
- State files are read with `kv_load`/`kv_get` and written with `kv_save`/`write_atomic`. Never `source` a state or settings file.
- Validate every external value with a predicate from `lib/validate.sh` or `lib/ip.sh` before it reaches a file.
- Functions returning through a nameref use locals with a unique prefix (`_x6_res`): bash scoping is dynamic.
- Do not write `cmd | grep -q` under `pipefail` (SIGPIPE makes it fail at random); use `output_has PATTERN cmd...`.
- Temporary directories: `make_tmp_dir VAR [PARENT]`; they are removed on exit.
- Secrets in files: `write_secret_file` (mode 600, refuses existing files and symlinks).
- Comments are in English and explain *why*, not *what*. User-facing messages are in Russian.
- ShellCheck must pass; the few disabled checks are listed with reasons in `.shellcheckrc`.

## Adding a command

Create `commands/<name>.sh` (two words: `commands/<group>-<name>.sh`, called as `wg-network <group> <name>`). Nothing has to be registered: `help`, the dispatcher and completion find it.

```bash
# shellcheck shell=bash

CMD_SUMMARY='one-line description for help'
CMD_GROUP=peers          # setup | peers | apply | diag | maintenance
CMD_MUTATES=1            # changes state: runs in a sandbox under --dry-run

cmd_usage() {
    cat <<'EOF'
Использование: wg-network [-i IFACE] example NAME [--flag]
EOF
}

cmd_run() {
    local name=''
    while (($#)); do
        case $1 in
            -*) die_unknown_arg "$1" ;;
            *) name=$1; shift ;;
        esac
    done
    is_name "$name" || die_usage "некорректное имя: $name"
    require_managed
    st_node_load

    tx_begin example            # lock, recover, refuse while pending, snapshot
    # ... change the desired state (st_peer_save, st_node_save) ...
    apply_changes               # plan, guards, approval, apply, confirmation
    tx_commit
    log_ok "готово: $(outcome_text)"
}
```

Metadata:

| Variable | Default | Meaning |
|---|---|---|
| `CMD_SUMMARY` | empty | text in `wg-network help` |
| `CMD_GROUP` | `other` | help section |
| `CMD_ROOT` | 1 | requires root |
| `CMD_IFACE` | 1 | resolves `-i` / the default interface before `cmd_run` |
| `CMD_MUTATES` | 0 | changes state; with `--dry-run` it runs on a sandbox copy |
| `CMD_READONLY` | 0 | only reads; allowed with `--dry-run` as is |
| `CMD_MIGRATE` | 1 | run the legacy migration first |

A command that is neither `CMD_MUTATES` nor `CMD_READONLY` refuses `--dry-run`. Following the `tx_begin` → change → `apply_changes` → `tx_commit` pattern gives the new command snapshots, crash recovery, plans, guards, confirmation, rollback and dry-run for free.

## Tests

```bash
tests/run.sh             # lint + unit + e2e
tests/run.sh lint        # ShellCheck of every script, tests included
tests/run.sh unit        # pure logic, no root
tests/run.sh e2e         # real WireGuard in namespaces
tests/run.sh systemd     # real systemd + OpenSSH in docker
tests/run.sh distro      # e2e inside Ubuntu 22.04 and 26.04 containers
tests/run.sh coverage    # unit + e2e (+ systemd + distro with COVERAGE_FULL=1) and the report
```

| Level | What it covers |
|---|---|
| lint | ShellCheck of the program, the installer, the completion, the tests and the stubs |
| unit | IPv4/IPv6 arithmetic, CIDR normalization, validation including injection attempts, tokens, rendering, the canonical comparison, atomic writes, symlink protection |
| e2e | 17 nodes in separate network namespaces with the **kernel WireGuard module** and real `wg`/`wg-quick`; only systemd, logger and the firewall front-ends are stubbed |
| systemd | **real systemd (PID 1) and OpenSSH** in containers: `wg-quick@`, the transient rollback timer, rollback across a **real container restart**, the hardened `reresolve` service, journald, `deploy` over SSH, install/uninstall with units |
| distro | the whole e2e suite inside Ubuntu 22.04 and 26.04 (their own bash, iproute2, wireguard-tools) |

e2e scenarios include:

- hub and peers, peer to peer through the hub, IPv4/IPv6 dual-stack;
- site-to-site with a host in the office LAN, exit node with NAT (the address seen by an outside web server is checked), full tunnel;
- DNS endpoints and re-resolution after the hub "changes IP";
- link loss, 30% packet loss (netem), a roaming peer;
- the SSH guard on real TCP sessions, including an asymmetric one;
- fault injection into `syncconf` and `wg-quick up`, a failing rollback reported honestly;
- confirmation timeout, confirmation from another session, a "reboot" before confirmation, an SSH drop while waiting, interactive mode through a pty;
- manual edits, the kernel diverging from the config, preshared key rotation;
- concurrent commands and locks, recovery after `kill -9`, PID reuse;
- a full disk and a read-only file system;
- 250 peers;
- legacy migration (successful and failing), backup → destroy → restore;
- `--dry-run` verified by fingerprinting files, kernel, routes and firewall for every changing command;
- over 90 invalid command lines (exit code and no side effects);
- no leftover temporary files.

The host is never changed: e2e runs in user, mount and network namespaces with overlays over `/etc`, `/opt`, `/usr/local/bin` and `/var/backups`; containers have their own namespaces.

Requirements:

- e2e: `wg` and `wg-quick` (`wireguard-tools`, or a directory with them in `WGTOOLS_DIR`), the `wireguard` module, and unprivileged user namespaces or `sudo` (Ubuntu 24.04 restricts user namespaces through AppArmor: use `sudo tests/run.sh e2e`);
- systemd and distro: docker.

Useful variables: `WGN_E2E_KEEP=1` keeps the work directory, `WGN_SYSTEMD_BASES="ubuntu:22.04 ubuntu:24.04"` and `WGN_E2E_BASES` choose the images.

The suites run from a copy of the sources: bash reads scripts incrementally, so editing a file during a run would break it.

## Coverage

Coverage is measured, not estimated. `BASH_ENV` enables xtrace into a per-process file in every bash process of the tests, including processes started by systemd inside the containers; the code itself is not changed. `tests/coverage/report.py` reports three metrics per file:

- **statements**: executable statements (a multi-line command counts once);
- **branches**: bodies of `if`/`elif`/`else` and every `case` label;
- **guards**: error checks (`|| die`, `|| return`, `&& die`) that actually fired, i.e. how many negative paths were exercised.

```bash
tests/run.sh coverage --min-statements 88 --min-guards 55               # unit + e2e
sudo -E env COVERAGE_FULL=1 tests/run.sh coverage --uncovered           # everything, list uncovered lines
```

The JSON report is written to `tests/coverage/last.json` (ignored by git). Traces contain test keys and are deleted unless `WGN_COV_KEEP=1`.

## Continuous integration

`.github/workflows/wg-network.yml` runs on changes under `ubuntu/wg/`:

1. lint and unit;
2. e2e as root on the runner (a disposable VM);
3. the systemd suite on Ubuntu 22.04 and 24.04;
4. coverage with thresholds, uploading `last.json` as an artifact.

## Releasing

1. Update `VERSION`.
2. Run `tests/run.sh all`, `tests/run.sh systemd` and `tests/run.sh distro`.
3. Tag the commit; users pin it with `install.sh --ref <tag>` or `self-update --ref <tag>`.
