# Audit

An independent review of the result: ubuntu-bootstrap (self-audit after implementation, the test runs and a second pass over the code) and wg-network (`ubuntu/wg`, read-only code review — the directory lives in the main checkout and is maintained separately; fixes are proposed as a list).

## ubuntu-bootstrap

### Fixed in the first iteration (implementation and tests)

| Finding | Where | Fix |
|---|---|---|
| The original script compared the nginx.org key fingerprint with the **first** key of the file, but the file holds three keys → installing from nginx.org always failed | `apt_repo_add` | membership of the official fingerprint in the list of all keys is checked |
| A port change on Ubuntu 22.10+ through `systemctl reload ssh` has no effect (socket activation, LP#2069041) | `sshd_apply` | `daemon-reload` + `restart ssh.socket`, verification with `ss` afterwards |
| `exec 3<>/dev/tcp/… 2>/dev/null` made the stderr redirection permanent — output after the self-check was lost | `ssh_selfcheck` | `{ exec 3<>…; } 2>/dev/null` |
| `systemctl reload fail2ban` right after `enable --now` hit the start-up phase and failed | `modules/fail2ban.sh` | reload only for an already running service; wait for the jail |
| The recover unit with `Before=ssh.socket` called `restart ssh.socket` → systemd job cycle, boot stuck | `systemd/…recover.service` | no ordering dependency on sshd, `WantedBy=multi-user.target`, `TimeoutStartSec=300` |
| `render \| file_write` ran in a subshell: `FILE_CHANGED` was lost and modules did not reload services | entry point | `shopt -s lastpipe` |
| `sshd -T` fails without `/run/sshd` (socket activation before the first connection) | `sshd_ready` | the directory is created before the call |
| Removing the old SSH port from UFW: the rule is `LIMIT`, not `ALLOW`; `ufw delete` of a missing rule returns 0 | `modules/ssh.sh` | the action is taken from `ufw status` |
| `plan` on a fresh server refused to disable passwords: the user did not exist yet | `plan_mark`, `human_users` | dry-run "planned facts" |
| `is_duration` rejected `1month` (journald) → `config init` produced an invalid config | `lib/validate.sh` | extended unit list; a unit test validates every profile |
| The audit treated `!` in `/etc/shadow` as an "empty password" | `commands/audit.sh` | only a truly empty field counts |
| SIGHUP on a dropped SSH session killed `apt-get` half-way | `run` | children ignore HUP; bash handles the signal between commands and redirects output to the log |
| In `SSH_CONFIRM=wait` mode the old port was closed in UFW before confirmation — a window without access if the new port did not work | `modules/ssh.sh` | the old port is closed only after confirmation (`mod_confirmed`); SSH rules are tagged with a comment |
| `ufw` rewrites its files in ASCII: non-ASCII comments in the `after.rules` block broke `ufw default` | `fw_docker_block` | ASCII-only comments |
| fail2ban on 22.04: `python3-systemd` is only Recommends, the jail with `backend=systemd` did not start | `modules/fail2ban.sh` | the package is installed explicitly |
| Docker-in-Docker in the tests: overlay on overlay does not mount | `tests/e2e.sh` | `/var/lib/docker` and `/var/lib/containerd` as separate volumes |

### Fixed in the second iteration (code audit)

| Finding | Where | Fix |
|---|---|---|
| Confirmations (`confirm_danger`) in users, docker and firewall were asked **after** part of the changes: a refusal left a half-applied module in state `refused` | `modules/users.sh`, `modules/docker.sh`, `modules/firewall.sh` | all confirmations moved to the top of `mod_apply`; the runner additionally rolls back the module's journal records on code 3, so "stopped by a guard" is guaranteed to mean "nothing changed" |
| `confirm_or_rollback` in `none` mode refused with a guard only after sshd had restarted / UFW was enabled | `lib/runner.sh`, `ssh_guards`, firewall | `*_CONFIRM=none` is checked in the guard phase, before changes |
| The sysctl module mutated `CONF[SYSCTL_BBR]` when `tcp_bbr` was unavailable, so the configuration hash never matched and the module re-ran on every apply | `modules/sysctl.sh` | BBR availability is a separate function; `CONF` is not mutated; unit tests for both cases |
| `mapfile -t keys < <(admin_keys_collect) \|\| return 1` lost the exit status of the process substitution: an invalid GitHub login did not stop the module | `modules/users.sh` | the result is captured in a variable with its status checked |
| The users module's `mod_check` fetched keys from GitHub on every `status`/`apply` | `modules/users.sh` | an offline check: with keys configured the user must have `authorized_keys` |
| `kv_set` rewrote `run.env`/state files in random key order | `lib/core.sh` | `kv_load` returns the key order, `kv_set` preserves it |
| The order of custom modules with equal priority depended on a hash of the name | `lib/modules.sh` | unknown modules follow the canonical ones alphabetically |
| The firewall module's `mod_verify` was skipped in every container, although UFW works there with `NET_ADMIN` | `modules/firewall.sh` | one availability check (`fw_available`) for apply and verify |
| Changing the timezone had no undo command | `modules/base.sh` | `undo timedatectl set-timezone <previous>` |
| `config set` forced `DRY_RUN` off | `commands/config.sh` | honours `--dry-run`: shows the diff, writes nothing |
| Dead code: `CMD_MUTATES`, `require_cmd`, `sha256_of`, `human_bytes`, `pkg_version`, `apt_candidate`, `cfg_is_set`, `check_that*`, `svc_restart`, `svc_reload_or_restart`, `UBB_HTTP_AUTH_HEADER`, an unused line in `audit_system`, the `E_OK`/`E_UNSUPPORTED` codes | everywhere | removed |
| Comments and headers of generated files in Russian (including files read by third-party tools) | all code | comments rewritten in English and trimmed; interface texts remain Russian |
| e2e: the test ssh client hung forever when a fail2ban ban (REJECT) landed on an already established connection | `tests/e2e.sh` | ssh calls wrapped in `timeout` |

### Remaining risks and assumptions

- `SSH_CONFIRM=auto` without a terminal confirms through a local self-check (sshd banner on the new port, port allowed in UFW). It cannot see provider filters (security groups) — use `SSH_CONFIRM=wait` + `confirm` from a new session for those.
- `--set ADMIN_PASSWORD_HASH=…` is visible in `ps` while the command runs; a configuration file (600, root) is the better place for secrets.
- A rollback does not remove packages or undo `apt upgrade`; `rollback RUN_ID` restores configuration and reloads services.
- TERM/HUP signals are handled between steps: the current command finishes, then the run is marked `interrupted`; dpkg is never interrupted half-way.
- `ADMIN_SSH_KEYS_GITHUB` keys are trusted via GitHub + TLS; the `git` module takes GitHub host keys from `api.github.com/meta`, other hosts via `ssh-keyscan` with fingerprints shown.
- `--force` lifts every guard at once. That is the administrator's deliberate choice; the rollback timer and confirmations remain.
- Inside containers swap, the NTP daemon and snap are skipped; sysctl is applied live only for writable keys.
- Release signatures are verified only with `UBB_SIGNING_KEY_FPR` set (the key is fetched from keys.openpgp.org); without it trust is TLS + the release's SHA256SUMS, as with get.docker.com.
- `public_ip` for the certbot DNS check queries `api.ipify.org`; when unreachable the default-route interface IP is used, which behind NAT yields a false refusal (`CERTBOT_DNS_CHECK=no`).

## wg-network (`ubuntu/wg`, v2.0.0)

The `ubuntu/wg` directory changes in parallel, so the findings were checked against the files as they were when this work finished.

Overall assessment: the architecture is sound — transactions with snapshots, guards for SSH routes, a dead-man timer outside the session, reboot protection through an `ExecStartPre` drop-in, validation of every input, atomic writes with mode 600, a trust check of the program directory. Below is what is worth fixing.

| # | Severity | Finding | Recommendation |
|---|---|---|---|
| 1 | medium | `install.sh` downloads `api.github.com/repos/…/tarball/REF`: 60 requests/hour per IP without a token (an office NAT or CI hits it), no way to pin the content except `--ref <sha>`, no release checksum verification | use `github.com/<repo>/archive/<ref>.tar.gz` without a token (not rate-limited like the API), add `--sha256` and release `SHA256SUMS` as in `ubuntu/bootstrap/install.sh` |
| 2 | low | `fetch_remote`: `curl` without `--max-time` — a stalled TLS stream blocks the installation forever | `--max-time 120` (`wget` has `--timeout`, but it applies to reads, not the whole operation) |
| 3 | low | `sys_install_wireguard` calls `apt-get` without waiting for the dpkg lock: right after boot unattended-upgrades holds it and `init-peer` fails | wait for `/var/lib/dpkg/lock-frontend` to be released (see `apt_wait` in bootstrap) |
| 4 | low | `kv_load` accepts any key before `=` (including ones with spaces); `st_validate` checks values but not key names — a corrupt `node.env` with the key `ROLE =hub` silently yields an empty `ROLE` and the message "ROLE must be hub or peer" without pointing at the cause | validate key names with `^[A-Z][A-Z0-9_]*$` and report the line |
| 5 | low | The `invite` token contains the PSK and is printed to stdout; the README advises pasting it on request — good, but `invite` does not warn that the token is single-use by nature and must not travel through open channels | add a warning to the `invite` output and a lifetime for the reservation (`PENDING` without a TTL stays forever) |
| 6 | low | `deadman_wait` with `--yes` and `GUARD_LEVEL=0` confirms automatically right after `apply_postcheck` — fine for a `restart` that does not touch the SSH session, but it should log which checks passed (address, port, peer in the kernel) | extend the message with the list of checks |
| 7 | info | `tests/run.sh e2e` needs unprivileged user namespaces; on hosts with `kernel.unprivileged_userns_clone=0` or an AppArmor restriction (Ubuntu 24.04 restricts userns for unconfined profiles by default) the tests silently skip the network part | document `sudo tests/run.sh e2e` as the fallback |
| 8 | info | The two tools duplicate infrastructure (core/validate/ip, the test framework). This is deliberate independence; as they grow, a shared `ubuntu/lib` is worth considering | maintainer's decision |

Integration with bootstrap: the `wg-network` module only installs the tool (`ubuntu/wg/install.sh` of the same repository and ref); the network is configured by `wg-network` separately; the `sysctl` module keeps `ip_forward` enabled when WireGuard is installed; the `firewall` module does not touch WireGuard UDP ports (`wg-network init-hub` opens them itself).
