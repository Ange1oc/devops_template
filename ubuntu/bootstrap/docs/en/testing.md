# Testing

```
tests/run.sh lint        shellcheck -S style for every script (local binary or docker koalaman/shellcheck)
tests/run.sh unit        tests/unit.sh — no root, network or system changes
tests/run.sh e2e         tests/e2e.sh — Ubuntu containers with systemd
tests/run.sh coverage    e2e + unit under kcov (Ubuntu 26.04), summary in tests/.coverage-summary.txt
tests/run.sh all         lint + unit + e2e
```

The host is never modified: everything that needs root runs inside containers.

## Lint

`shellcheck -x -S style` over the entry point, `install.sh`, `lib/*.sh`, `commands/*.sh`, `modules/*.sh`, `completion/*.bash`, `tests/*.sh`. Three warnings are disabled globally in `.shellcheckrc` with a reason each (SC2034 — variables are used across files through `source`; SC2153 — associative array keys; SC2015 — deliberate `A && B || C`).

## Unit (`tests/unit.sh`)

The libraries are sourced directly into the test process; state paths are moved into a sandbox via `UBB_SYSROOT`, so transactions, module state and rollback timers work in a temporary directory. About 200 checks:

- validators (ports, keys, hostnames, CIDRs, sizes, durations, e-mail, git refs, user names);
- `KEY=VALUE`: reading, writing with key order preserved, rejection of garbage and lower-case keys; lists, `join_by`, `in_list`, `json_str`;
- facts from `os-release`;
- module registry: discovery of 17 modules, order, dependencies (`certbot → preflight`, `ssh docker firewall`, `fail2ban` after `ssh` and `firewall`), cycle detection through custom modules, the default set, option ownership, the adv flag;
- options of every type; precedence profile → file → `--set`; `MODULES_ADD/SKIP`; rejection of an unknown option, an invalid value, an unknown module, a corrupt config, a missing profile; `--only` with dependencies and `--skip`; validity of every built-in profile;
- transactions: journal, `config_save`, `file_write` (creation, idempotence, change, permissions, backup, `W` records), `undo`, `file_set_block` (add, replace, remove, foreign lines preserved), `file_remove`, rollback of one module and of the whole run, dry-run writes nothing, secret masking, `run`, statuses, module state, configuration hash;
- deferred rollback via `setsid` (no systemd): `pending_arm/disarm/rollback/confirm`;
- module config rendering: ssh (Port, AllowUsers, KbdInteractive), fail2ban (ignoreip, journalmatch), firewall (rules, DOCKER-USER, `cidr_contains4`), sysctl (ip_forward, BBR depending on kernel availability and containers), docker (valid JSON, merge with a foreign `daemon.json`), updates, journald, limits, nginx, swap (auto size), users (key collection);
- audit: counters, exit codes, valid JSON;
- CLI without root: `version --json`, `modules --json`, `help`, exit codes on usage errors, `config validate` with a typo, `install.sh --help`, `bash -n` of every file.

## E2E (`tests/e2e.sh`)

```
tests/e2e.sh [--version 24.04] [--only NAME[,NAME]] [--keep] [--coverage]
UBUNTU_VERSIONS="22.04 24.04 26.04" tests/e2e.sh
```

The image `tests/docker/Dockerfile` imitates Ubuntu Server: systemd as PID 1, `openssh-server` (socket-activated on 24.04+), `ufw`, `sudo`, `unattended-upgrades`, `rsyslog`, a known root password. Containers run with `--privileged --cgroupns=private` (iptables, docker-in-docker), `/var/lib/docker` and `/var/lib/containerd` are separate volumes (overlay on overlay does not mount), the sources are mounted read-only at `/src`, ports 22/2222/2200 are published on `127.0.0.1`. The tests log in over SSH **from the host** with a real client and key and check which authentication methods sshd offers.

| Container | Scenarios |
|---|---|
| A | `install` (install, reinstall keeping `.old`, `--rollback`, rejection of bad `--ref`/`--sha256`, refusal to install a tree with a syntax error, `doctor`, `audit` on a fresh system) → `fresh` (`plan` changes nothing, `apply` minimal, real key login and `sudo -n`, no password offered, UFW limit, fail2ban, unattended, journald, `status`, `audit`, `history`, backups) → `fail2ban` (a ban after real failed logins, `journalmatch`, unban) → `idempotent` (a second `apply` skips everything but preflight, `--reapply` changes no files and does not duplicate keys) → `port` (22→2222: self-check, `ssh.socket`, UFW, fail2ban re-applied, old port closed) → `pending` (`SSH_CONFIRM=wait`: systemd timer, `apply` while pending → 5, rollback by timer, login on the old port; `confirm` over ssh through the new port, old port closed after confirm) → `reboot` (`docker restart` with a pending change: the recover service rolls back, sshd/ufw/fail2ban alive) → `rollback` (`history RUN_ID`, `rollback --module`, usage errors) → `failures` (a custom failing module: file and `undo` rolled back, state `failed`, stop without `--keep-going`, continue with it, the fixed module applies, a non-existent package) → `interrupt` (SIGTERM: status `interrupted`, the lock does not stick, manual rollback; SIGKILL: `doctor` sees `running`) → `uninstall` (services keep running) |
| B | `guards` (no keys → 3; `PermitRootLogin no` without an administrator → 3; `auto` → prohibit-password and a real root key login; `AllowUsers` without keys → 3; users without a password → warning and root's keys copied; `PermitRootLogin no` with non-working sudo → 3; password from a hash; then root can no longer log in, deploy can) → `corrupt` (garbage in the config, an invalid value with its source, a typo in a name, `config get/show`) → `wg` (wg-network installation when `ubuntu/wg/install.sh` is reachable on GitHub) |
| C | `preconfigured` (cloud-init `PasswordAuthentication yes`, an existing user with a key and sudoers, UFW with foreign rules: rules kept, `00-` wins, keys untouched, `after.rules` backed up) → `network` (REJECT 80/443: the nginx module fails without hanging, source and keyring not left behind; `doctor` after recovery) → `services` (profile full without git/wg/swap: Docker from deb822 with a verified fingerprint, `daemon.json`, compose, DOCKER-USER in iptables, nginx.org, `server_tokens off`, `LimitNOFILE`, 80/443 open, certbot from apt, DNS guard → 3; a container publishing on `0.0.0.0` is unreachable from a neighbouring container, reachable after `FW_DOCKER_ALLOW_PORTS`, the host's nginx reachable) |

Options: `--version` — one or several versions separated by spaces; `--only` — a list of scenarios (`install fresh fail2ban idempotent port pending reboot rollback failures interrupt uninstall guards corrupt wg preconfigured network services`); `--keep` — keep the containers after the run; `UBB_REBUILD=1` — rebuild the image.

Quirks the tests account for: `ufw limit` admits at most 6 new connections per 30 seconds from one IP, so SSH-heavy steps are spaced out; a fail2ban REJECT on an established connection is a soft TCP error and would hang the ssh client during the handshake, so every ssh call runs under `timeout`; Docker Desktop occasionally fails to bind-mount on the first attempt, so the container start is retried up to three times; `systemd-detect-virt` inside containers on WSL2 reports `wsl`, which counts as a container.

Latest full run results: 22.04 — 205 checks, 24.04 — 203, 26.04 — 206, no failures.

## Coverage

```
tests/run.sh coverage            # UBB_COV_DIR=... overrides the report directory
```

kcov instruments bash through the DEBUG trap. Every `ubuntu-bootstrap` invocation in e2e writes a separate `cobertura.xml`; `tests/coverage-merge.py` merges them as "a line is covered when any run covered it" (`kcov --merge` yields an empty result for bash reports) and prints a per-file table. kcov is in apt on Ubuntu 26.04 (absent on 24.04), so coverage is measured there. Reports are created by root inside the container and live outside the source tree (`$TMPDIR/ubuntu-bootstrap-coverage`), because `/src` is mounted read-only.

Measured coverage: about 35 % of lines over the union of unit and e2e. The figure is understated: the rollback timer and the recover service run as separate processes through `systemd-run` and are not instrumented; the wizard is checked manually through a pseudo-tty; the snap path of certbot, swap and part of sysctl are unavailable in containers.

## CI

`.github/workflows/ubuntu-bootstrap.yml`: on changes under `ubuntu/bootstrap/**` — `lint-unit`, then e2e as a 22.04 / 24.04 / 26.04 matrix (privileged containers on `ubuntu-latest`) and coverage with the summary published as an artifact.

`.github/workflows/ubuntu-bootstrap-release.yml`: a tag `ubuntu-bootstrap-vX.Y.Z` → check that it matches `VERSION`, lint and unit, a reproducible tarball (`--owner=0 --group=0 --mtime --sort=name`), `SHA256SUMS`, a `SHA256SUMS.asc` signature when the `UBB_GPG_PRIVATE_KEY` secret exists, a GitHub Release.

## What the tests do not cover

- Real Let's Encrypt issuance (needs a public domain): certbot installation, the DNS guard and the logic are tested.
- The snap installation of certbot (snapd does not work in containers): the apt path is covered.
- swap and kernel sysctl: they belong to the container host; file rendering is covered by unit tests.
- arm64: the tests run on amd64; there is no architecture-specific code (the architecture is substituted into deb822).
- The interactive wizard: checked manually.
- Systems without systemd: the `setsid` rollback timer is covered by a unit test, the full scenario is not.
