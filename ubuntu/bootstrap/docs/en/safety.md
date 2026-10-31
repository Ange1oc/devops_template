# Safety and reliability

The tool changes the most sensitive parts of a server: SSH access, the firewall, sudo. Its protection has four layers: guards before changes, confirmation of risky changes with automatic rollback, a transactional journal with backups, and respect for foreign configuration.

## Guards

A guard is a check that stops a module **before** any change with exit code 3. It is independent of `--yes` (that flag only answers questions) and is lifted only by `--force`, when the administrator consciously accepts the risk. A module stopped by a guard leaves the system untouched: whatever it managed to write is rolled back.

| Module | Guard |
|---|---|
| preflight | OS is not Ubuntu or the version is not 22.04/24.04/26.04; free space on `/` below `PREFLIGHT_MIN_DISK_GB` |
| ssh | `sshd_config` does not include `sshd_config.d/*.conf`; disabling passwords when no allowed user has `authorized_keys`; `PermitRootLogin no` without a user with a key **and working sudo**; `AllowUsers` excludes the user of the current session; the new port is in use; `SSH_CONFIRM=none` |
| firewall | `FW_SSH_FROM` does not include the current session's IP; `FW_CONFIRM=none` with a remote session |
| docker | conflicting packages installed with `DOCKER_REMOVE_CONFLICTS=no` |
| certbot | the domains' DNS does not point at this server (`CERTBOT_DNS_CHECK`) |
| any | `confirm_or_rollback` in `none` mode without `--force` |

"Working sudo" means: the user is in the `sudo` group and either has a password or has a `NOPASSWD` entry in sudoers. A user created with `adduser --disabled-password` does not qualify, and disabling root for them would mean losing administrative access.

In dry-run (`plan`) the guards work exactly as in a real apply; modules record "planned facts" (a user will be created, keys will be added, sudo will be configured), so a plan on a fresh server shows the same outcome as `apply`.

## Confirmation of dangerous actions

Some actions are not blocked but need explicit consent (`confirm_danger`): on a terminal the word `yes` must be typed, `--yes` accepts automatically, without a terminal and without `--yes` the action is refused (code 3). All such questions are asked before the module changes anything.

| Action | Where |
|---|---|
| `NOPASSWD:ALL` for the administrator | users |
| `PermitRootLogin yes` | ssh |
| enabling UFW (with the list of ports to open) | firewall |
| removing `docker.io`/`containerd`/`runc` and other conflicting packages | docker |
| adding a user to the `docker` group | docker |
| rolling back a run by `RUN_ID` | rollback |

## Access confirmation and the rollback timer

After applying the sshd configuration or enabling UFW there is a window in which a mistake (a port closed by the provider, a typo in `AllowUsers`, a key of the wrong user) leaves the server unreachable. The mechanism:

1. The module applies the change and calls `confirm_or_rollback`.
2. A rollback timer is armed **outside the SSH session**: a transient unit `systemd-run --on-active=<TIMEOUT>s --unit ubuntu-bootstrap-rollback-<module>` (without systemd a detached `setsid` process). A dropped session does not stop the timer.
3. `/var/lib/ubuntu-bootstrap/pending.env` is written: `RUN_ID`, `MODULE`, `DEADLINE`, `MECH` (systemd/setsid), `TIMER`, `DESC`.
4. What follows depends on the mode (`SSH_CONFIRM`, `FW_CONFIRM`):
   - **auto, interactive**: a countdown with a question; `y` confirms, `n` or the timeout rolls back immediately. While the countdown runs, a new session can execute `confirm` — the main process notices it.
   - **auto, without a terminal** (`--yes`, cloud-init, CI): a self-check on the server — sshd answers with a banner on the new port over loopback and the port is allowed in UFW (for firewall: UFW is active and the SSH ports are allowed). Success confirms, failure rolls back. The self-check cannot see external filters (provider security groups).
   - **wait**: the process exits (code 0), the timer keeps running; `confirm` from a new session cancels it. For Ansible/CI that reconnect on the new port.
   - **none**: no timer; allowed only with `--force`.
5. Confirmation (`confirm`): the timer is stopped, `pending.env` removed, `CONFIRMED_AT` recorded in the module state, the `mod_confirmed` hook runs (ssh closes the old port in UFW).
6. Rollback (timer, `rollback --pending`, "no", a failed self-check): the module's journal records are replayed in reverse — files restored, undo commands executed (for ssh: the previous config re-applied with a socket restart, the new port removed from UFW; for firewall: rule files restored and UFW returned to its previous state). The module state becomes `rolled_back`, its configuration hash is cleared, an event goes to journald.

While a change waits for confirmation, a new `apply` exits with 5: run `confirm` or `rollback --pending` first.

### Reboot inside the waiting window

`ubuntu-bootstrap-recover.service` (enabled by the installer, `WantedBy=multi-user.target`, `ConditionPathExists=/var/lib/ubuntu-bootstrap/pending.env`) runs `rollback --pending --boot` at boot: unconfirmed changes are rolled back and sshd restarts with the previous config. The unit deliberately has no `Before=ssh.socket`: the rollback restarts `ssh.socket` itself and an ordering dependency would create a systemd job cycle.

### SSH drops during apply

`SIGHUP` does not interrupt the work: output is redirected to the run log and the process continues in the background. Child commands (`apt-get`, `dpkg`) run with `SIGHUP` ignored, so a package operation is never cut half-way. `SIGTERM`/`SIGINT` are handled between steps: the current command finishes, the run is marked `interrupted`, the lock is released. `doctor` shows such runs; `rollback RUN_ID` rolls them back manually.

### The old port during an SSH port change

The new port is opened in UFW before sshd restarts. The old port stays open until confirmation and is closed only afterwards — exclusively rules with the comment `SSH (ubuntu-bootstrap)` are removed. If the old port was opened by a foreign rule, the module warns and leaves it alone.

## Transactions

Every `apply`, `plan`, `wizard` and `config set|init` run is a transaction:

- **lock**: `flock` on `/var/lib/ubuntu-bootstrap/.lock`; a second instance exits with 5; the lock is not inherited by the rollback timer and does not stick after `SIGKILL`;
- **run directory** `/var/lib/ubuntu-bootstrap/runs/<RUN_ID>/` with `run.env` (status, command, version, time, user, dry-run) and `journal`;
- **journal**: one record per line, fields separated by `\x1f`: `M module` (module start), `W path backup|-` (file written; `-` means it did not exist), `D path backup` (file removed), `U argv...` (undo command);
- **backups**: `/var/backups/ubuntu-bootstrap/<RUN_ID>/<absolute path>` preserving mode and owner (`cp -a`), directories mode 700;
- **atomic writes**: content goes to a temporary file in the same directory, mode and owner are set before the file appears at its path, then `mv`. A file with identical content is not rewritten (only mode and owner when they differ), so a repeated run does not touch mtimes or restart services;
- **the undo command is registered before the change**: during the reverse replay the file is restored first and then the command runs (reload a service, delete a rule, remove a user). An undo command may be a module function — the module is loaded before it runs;
- **module failure** (non-zero `mod_apply`, failed `mod_verify`) replays this module's records in reverse, marks it `failed` and stops the run; `--keep-going` continues;
- **`rollback RUN_ID [--module M]`** replays the journal of any past run; the affected modules become `rolled_back`;
- **dry-run** journals and backs up nothing: `file_write` prints a diff, `run` prints the command.

What a rollback does not do: it does not remove installed packages and does not undo `apt-get upgrade`; services installed by a module are only stopped and disabled (docker, for example), configuration returns to its previous state.

## What the tool never touches

- Foreign files as a whole: only its own files (`*ubuntu-bootstrap*`, `00-ubuntu-bootstrap.conf`) and blocks between `# BEGIN ubuntu-bootstrap <name>` / `# END ...` markers inside `/etc/fstab`, `/etc/hosts`, `/etc/ufw/after.rules` are written. Other lines of those files are preserved byte for byte.
- Existing UFW rules: only missing ones are added; foreign SSH rules are not removed even on a port change.
- Docker's `daemon.json`: our keys are added, foreign ones (including `data-root` and a different `log-driver`) are kept.
- `authorized_keys`: keys are appended, existing lines stay.
- Existing users are not recreated; existing users' passwords are not changed (except setting the administrator's missing password from an explicit hash or the terminal).
- Package configs during `apt upgrade`: `--force-confold`.
- The source of an already installed nginx is not changed.
- Nothing is removed from `/var/lib/docker`.

## Trust in external sources

| What | How it is verified |
|---|---|
| The tool itself | HTTPS/TLS 1.2+ only; releases via `SHA256SUMS` and optionally a GPG signature; `--sha256`; `bash -n` on every file; refusal of trees with symlinks; atomic swap |
| Docker repository key | fingerprint `9DC858229FC7DD38854AE2D88D81803C0EBFCD88` compared before writing |
| nginx.org repository key | fingerprint `573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62` must be among the file's keys |
| Administrator keys from GitHub | `https://github.com/<login>.keys` over TLS; every key validated by format |
| GitHub host keys for deploy keys | `https://api.github.com/meta` over TLS; other hosts via `ssh-keyscan` with fingerprints printed |
| wg-network | downloaded from the same repository and ref as ubuntu-bootstrap itself, `bash -n` before running |
| Downloads in general | `curl --proto '=https' --tlsv1.2 --max-time 120`, redirects to http refused |

## Logs, audit, secrets

- Full run log: `/var/log/ubuntu-bootstrap/<RUN_ID>.log` (600): commands and their output, written files with backup paths, answers to questions, rollback events.
- journald: `logger -t ubuntu-bootstrap` for start, finish, refusals, rollbacks, confirmations — with the name of the user who ran the command.
- Secrets: the administrator's password is set through `passwd` on the terminal or as a crypt hash and never reaches the log; `ask_secret` is not logged; the dry-run diff masks `PASSWORD`, `TOKEN`, `SECRET`, `PrivateKey`. `--set ADMIN_PASSWORD_HASH=...` is visible in `ps` while the command runs — a configuration file (600, root) is the better place for secrets.
- State and configuration files are 600/700, owned by root.
- `doctor` verifies that `/opt/ubuntu-bootstrap` is owned by root and not writable by others, because the rollback timer and the recover service execute code from there as root.

## Limitations and residual risks

- The `SSH_CONFIRM=auto` self-check without a terminal sees only the server itself; it cannot check provider filters — use `SSH_CONFIRM=wait` + `confirm` from a new session for those.
- A rollback does not remove packages or undo system upgrades.
- `--force` lifts every guard at once, not selectively.
- Inside containers swap, the NTP daemon and snap are skipped; sysctl is applied live only for writable keys; UFW needs `NET_ADMIN`.
- Release signatures are verified only when `UBB_SIGNING_KEY_FPR` is set; otherwise trust is TLS plus `SHA256SUMS`.
- On systems without systemd the rollback timer is a plain background process that does not survive a reboot (the recover service needs systemd too).
- certbot automates HTTP-01 only (public DNS and an open port 80 are required); wildcard certificates (DNS-01) are not automated.
