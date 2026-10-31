# Usage

```
ubuntu-bootstrap [global options] <command> [command arguments]
ubuntu-bootstrap help [command]
ubuntu-bootstrap <command> --help
```

Global options go **before** the command. Root (`sudo`) is required by every command except `help`, `version`, `modules`, `profiles` and `doctor`: even `plan` reads `sshd -T`, module state and writes a run journal. Without root, `--dry-run` lets you validate a configuration file or profile: `ubuntu-bootstrap --dry-run --config server.conf config validate`.

## Global options

| Option | Purpose |
|---|---|
| `-p, --profile NAME` | profile: `minimal`, `web`, `docker`, `full` or a custom one from `/etc/ubuntu-bootstrap/profiles.d/`. Sets the module set and option defaults. Takes precedence over `PROFILE=` in the config file |
| `-c, --config FILE` | configuration file instead of `/etc/ubuntu-bootstrap/bootstrap.conf` |
| `-s, --set KEY=VALUE` | override an option; repeatable. Quote values with spaces as a whole: `--set 'ADMIN_SSH_KEYS=ssh-ed25519 AAAA... me'` |
| `--only M1,M2` | run only these modules and their dependencies (instead of the configured set) |
| `--skip M1,M2` | exclude modules from the set |
| `-n, --dry-run` | change nothing: show file diffs and commands. `plan` is the same as `apply --dry-run` |
| `-y, --yes` | non-interactive: questions get their default answer, dangerous actions (`confirm_danger`) count as confirmed. **Guards keep working**; only `--force` lifts them |
| `--keep-going` | on a module error or refusal continue with the next module (by default the run stops) |
| `--force` | lift guards: unsupported Ubuntu version, missing keys or sudo for the administrator, occupied port, `*_CONFIRM=none` and so on. Confirmations and the rollback timer remain |
| `-q, --quiet` | warnings and errors only |
| `-v, --verbose` | verbose output (every written file, permission changes) |
| `--json` | machine-readable output for `status`, `audit`, `modules`, `version` |
| `--no-color` | no colors (the `NO_COLOR` variable is honoured too) |
| `-V, --version` | same as the `version` command |

## Commands

### `wizard [--advanced]`

Interactive wizard. Needs a terminal (also works through `curl ... | sudo bash -s -- --run` by reading `/dev/tty`). Steps:

1. Server overview: OS, virtualization, resources, network, the current SSH session and sshd ports.
2. Profile choice (or a custom set without a profile). If `/etc/ubuntu-bootstrap/bootstrap.conf` exists, its values are offered as defaults.
3. Enable or disable each module; dependencies are enabled automatically, `preflight` always runs.
4. Options of every enabled module with hints and validation. Options marked as advanced are asked only after answering "yes" to the corresponding question or with `--advanced`.
5. Saving `/etc/ubuntu-bootstrap/bootstrap.conf` (with all options and descriptions).
6. Plan (dry-run): file diffs and commands that would run.
7. Apply. For risky modules the wizard asks you to open a new SSH session and confirm that login works; otherwise the change rolls back after the timeout.

Nothing changes before step 5. Running the wizard again reads the saved configuration, so it can be used to adjust settings later.

### `plan`

Dry-run: every module runs its checks and guards, prints file diffs (secrets masked) and commands, but changes nothing. The exit code is what `apply` would return: 3 if a guard would stop the run. Modules record "planned facts" (for example, that a user will be created), so a plan on a fresh server behaves like a real apply.

### `apply [--reapply]`

Applies the configured modules (or `--only`) in dependency order. For every module:

- if its state is `applied`, the option hash is unchanged and `mod_check` confirms the desired state, the module is skipped (`--reapply` disables the skip; `preflight` always runs);
- otherwise `mod_apply` runs, then `mod_verify`; success is recorded in the module state together with its option hash;
- a failure rolls back only this module's changes (files from backups and undo commands, in reverse order) and stops the run; `--keep-going` continues with the next module;
- a guard stop (code 3) leaves the system untouched: whatever the module wrote before refusing is rolled back.

If a change is waiting for confirmation (`pending.env`), `apply` exits with 5: run `confirm` or `rollback --pending` first.

### `confirm`

Confirms a risky change (SSH port change, enabling UFW) and cancels the rollback timer. Run it **from a new session** to prove that access works. After confirmation the module may perform deferred actions: `ssh` closes the old port in UFW.

### `rollback`

```
ubuntu-bootstrap rollback --pending [--auto|--boot]
ubuntu-bootstrap rollback RUN_ID [--module NAME]
ubuntu-bootstrap rollback --last [--module NAME]
```

- `--pending` rolls back the change waiting for confirmation (used manually, by the timer with `--auto` and by the recover service with `--boot`).
- `RUN_ID` rolls back a run from `history`: files are restored from its backups, undo commands run in reverse order; `--module` limits the rollback to one module. The journal is shown and a confirmation is requested first (`--yes` accepts).
- `--last` is the most recent run.

Packages are not removed by a rollback; it covers configuration, rules and service state.

### `status [--all] [--json]`

For every selected (or, with `--all`, every) module: `ok` means the desired state is reached; `config-changed` means applied but the options changed since; `pending` means not applied or the state does not match; `n/a` means not applicable inside a container. Shows the apply time and reminds about a pending confirmation. Exits 0 only when everything is current.

### `audit [--all] [--json]`

Security and readiness audit, read-only. System-wide checks: Ubuntu version, reboot required, available updates, failed services, users with empty passwords or UID 0, passwordless sudo, world-readable secrets in typical places, ports listening on all interfaces, AppArmor, free space, large logs. Then every module's checks (`mod_audit`). Exit code: 0 clean, 1 warnings, 2 problems. `--json` for monitoring.

### `doctor [--json]`

Diagnostics of the tool itself: OS and architecture, systemd, container, required commands, apt lock, HTTPS to `archive.ubuntu.com`, syntax of every file, installation metadata, permissions of `/opt/ubuntu-bootstrap`, the recover service, custom modules, config validity, runs in `running`/`interrupted` state, pending confirmations. Exit codes as for `audit`.

### `history [RUN_ID]`

Without an argument: a table of runs (id, status, command, dry-run, modules). With `RUN_ID`: its `run.env` and journal — written files (marked "new" when the file did not exist), removed files, undo commands, paths to the log and backups.

A run id is `YYYYMMDD-HHMMSS-PID`. Statuses: `running`, `done`, `failed`, `refused` (stopped by a guard), `rolled_back`, `interrupted` (process terminated).

### `config <show|validate|get|set|init|path>`

| Subcommand | Purpose |
|---|---|
| `show` | effective configuration of the selected modules and the source of every value: `profile:web`, `file:/etc/...`, `cli`, `default` |
| `validate` | check the configuration file and profile; an error names the key, value, expected type and source |
| `get KEY` | print the effective value of an option |
| `set KEY=VALUE...` | write values to `/etc/ubuntu-bootstrap/bootstrap.conf` (validated, previous file backed up) |
| `init [--profile NAME]` | create a configuration file from a profile with every option and description; an existing file is overwritten only with `--force` |
| `path` | path of the effective configuration file |

### `modules [--options] [MODULE]`, `profiles [NAME]`

Reference: the module table (group, in the default set, dependencies), details of one module with its options, every option of every module (`--options`); the profile list with descriptions and modules, the contents of a profile.

### `self-update [--ref REF] [--check]`, `version [--json]`

See [Installation](install.md#updating).

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | error (the module was rolled back; details in the output and log) |
| 2 | usage error: unknown command, argument or `--set` value |
| 3 | stopped by a guard; `--force` lifts it |
| 4 | changes rolled back: confirmation timer expired, "no" was answered or the self-check failed |
| 5 | busy: another process holds the lock, apt/dpkg stayed locked longer than the limit, or a change is waiting for confirmation |
| 130 | interrupted by a signal (Ctrl-C, SIGTERM); the run is marked `interrupted` |

`audit`, `doctor`: 0 / 1 (warnings) / 2 (problems). `status`: 0 when everything is current, 1 when something needs applying or confirming.

## Configuration

The file `/etc/ubuntu-bootstrap/bootstrap.conf` (mode 600, owned by root):

```
# comments and empty lines are skipped
PROFILE=web
MODULES_SKIP=swap
ADMIN_USER=deploy
ADMIN_SSH_KEYS=ssh-ed25519 AAAA... admin@laptop;ssh-ed25519 BBBB... admin@desk
SSH_PORT=2222
```

Format rules:

- one `KEY=VALUE` pair per line; keys are upper-case letters, digits and `_`;
- the value is taken verbatim up to the end of the line, without quotes or escaping; spaces inside values are fine;
- the file is **never executed** as a shell script: expansions, `$(...)` and the like do not work;
- an unknown key or a value of the wrong type is an error that names the source;
- an empty value means "not set" for most options (see each option's description).

Source precedence: `--set` > configuration file > profile > module default. `config show` prints where every value came from.

Core keys (not owned by modules):

| Key | Purpose |
|---|---|
| `PROFILE` | profile name; its file is read first |
| `MODULES` | full comma-separated module list; replaces the profile's list and the default set |
| `MODULES_ADD` | add modules to the set |
| `MODULES_SKIP` | remove modules from the set |

Module set: `MODULES` (or the default set when absent) plus `MODULES_ADD` minus `MODULES_SKIP`; dependencies and `preflight` are added afterwards. On the command line `--only` replaces the set entirely and `--skip` excludes.

### Option types

| Type | Accepted values | Examples |
|---|---|---|
| `bool` | `yes/no`, `true/false`, `on/off`, `1/0` | `yes` |
| `int` | integer ≥ 0 | `180` |
| `port` | 1–65535 | `2222` |
| `portkeep` | port or `keep` (do not change) | `keep` |
| `string` | one line | `04:00` |
| `list` | items separated by comma, semicolon or space | `curl,git jq` |
| `enum:a,b,c` | one of the listed values | `auto` |
| `user` / `users` | Linux user name (`^[a-z_][a-z0-9_-]{0,31}$`) / list | `deploy`, `deploy,ops` |
| `path` | absolute path | `/swapfile` |
| `size` | number with `M` or `G` suffix; some options also accept `auto` and `0` | `2G`, `512M` |
| `email` | e-mail address | `ops@example.com` |
| `duration` | fail2ban/systemd time span | `10m`, `1h`, `2weeks`, `1month` |
| `timezone` | name from `/usr/share/zoneinfo` | `Europe/Berlin` |
| `hostname` / `hostnames` | DNS name / list | `example.com,www.example.com` |
| `keys` | public SSH keys separated by `;` (ed25519, rsa, ecdsa, sk-*) | `ssh-ed25519 AAAA... a;ssh-rsa BBBB... b` |
| `ports` | list of `PORT` or `PORT/tcp|udp` | `8443/tcp,51820/udp,9000` |
| `cidrs` | list of IPs or CIDRs (IPv4/IPv6) | `203.0.113.0/24,2001:db8::1` |

### Profiles

| Profile | Modules | Profile options |
|---|---|---|
| `minimal` | preflight base time users ssh firewall fail2ban updates journald | — |
| `web` | minimal + sysctl limits swap nginx certbot | `NGINX_SOURCE=stable`, `FW_WEB=yes` |
| `docker` | minimal + sysctl limits swap docker | `FW_DOCKER_PROTECT=yes` |
| `full` | web + docker + git + wg-network | `NGINX_SOURCE=stable`, `FW_WEB=yes`, `FW_DOCKER_PROTECT=yes` |

A custom profile is a file `/etc/ubuntu-bootstrap/profiles.d/<name>.conf` in the same format; its first comment line becomes the description shown by `profiles` and the wizard. Name: lower-case letters, digits and hyphens, up to 32 characters. A custom profile with the same name as a built-in one takes precedence.

## Scenarios

### Fresh server, interactively

```bash
curl -fsSL https://raw.githubusercontent.com/Ange1oc/devops_template/main/ubuntu/bootstrap/install.sh | sudo bash -s -- --run
```

The wizard offers the `minimal` profile and the user `deploy`, copies root's keys to the new user (when no other keys are given), disables password login, disables root login (when the administrator has a key and working sudo), enables UFW and fail2ban, automatic updates and a persistent journal. A port change or enabling UFW ends with an access check from a new session.

### Non-interactively

```bash
sudo ubuntu-bootstrap apply --profile minimal \
    --set ADMIN_USER=deploy --set 'ADMIN_SSH_KEYS=ssh-ed25519 AAAA... admin' \
    --set ADMIN_SUDO_MODE=nopasswd --yes
```

`--yes` answers "yes" to dangerous-action confirmations (NOPASSWD, enabling UFW, removing conflicting Docker packages) and supplies defaults. Guards are not lifted: if `deploy` has no key, password login is not disabled, the command exits with 3 and changes nothing.

Access confirmation without a terminal (`SSH_CONFIRM=auto`, the default) is a self-check on the server: sshd answers on the new port and the port is allowed in UFW. A provider firewall (security group) between you and the server is invisible to the self-check — use `SSH_CONFIRM=wait` and `confirm` from a new session in such environments.

### Configuration file kept in a repository

```bash
sudo ubuntu-bootstrap --config ./servers/web01.conf plan
sudo ubuntu-bootstrap --config ./servers/web01.conf apply --yes
```

Example file: [examples/web.conf](../../examples/web.conf). Keep secrets such as `ADMIN_PASSWORD_HASH` in a file with mode 600 rather than passing them via `--set`: command-line arguments are visible in `ps`.

### cloud-init

```yaml
#cloud-config
runcmd:
  - curl -fsSL https://raw.githubusercontent.com/Ange1oc/devops_template/main/ubuntu/bootstrap/install.sh | bash -s -- --ref main
  - >
    ubuntu-bootstrap apply --profile minimal
    --set ADMIN_USER=deploy
    --set 'ADMIN_SSH_KEYS=ssh-ed25519 AAAA... admin@laptop'
    --set ADMIN_SUDO_MODE=nopasswd
    --set SSH_CONFIRM=auto
    --yes
```

On first boot there is no SSH session, so UFW is enabled without waiting for confirmation and sshd is confirmed by the self-check. Full example: [examples/cloud-init.yaml](../../examples/cloud-init.yaml).

### Ansible / CI with a port change

Use `SSH_CONFIRM=wait`: the process does not block, the timer is armed, the playbook reconnects on the new port and runs `confirm`:

```yaml
- command: >
    ubuntu-bootstrap apply --profile minimal --set ADMIN_USER=deploy
    --set 'ADMIN_SSH_KEYS={{ admin_pubkey }}' --set ADMIN_SUDO_MODE=nopasswd
    --set SSH_PORT=2222 --set SSH_CONFIRM=wait --set SSH_CONFIRM_TIMEOUT=300 --yes
  register: apply
  failed_when: apply.rc not in [0, 4]
- set_fact: { ansible_port: 2222 }
- command: ubuntu-bootstrap confirm
```

If the reconnection fails, the port reverts after 300 seconds; the old port stays open in UFW the whole time. Full example: [examples/ansible.yml](../../examples/ansible.yml).

### Changing settings after apply

```bash
sudo ubuntu-bootstrap config set SSH_PORT=2222 F2B_MAXRETRY=3
sudo ubuntu-bootstrap plan
sudo ubuntu-bootstrap apply
```

Only modules whose options changed or whose state no longer matches are re-applied. `apply --reapply` re-runs every selected module (idempotently: files with identical content are not rewritten).

### SSH port change: what happens

1. Guards: the new port is free; allowed users have keys.
2. If UFW is active, the new port is opened in it **before** sshd restarts (with the same action the firewall module uses: `limit` or `allow`).
3. `/etc/ssh/sshd_config.d/00-ubuntu-bootstrap.conf` is written, `sshd -t` validates it, sshd restarts (on Ubuntu 22.10+ via `ssh.socket`, otherwise the port would not change). The current session survives the restart.
4. The rollback timer is armed (`SSH_CONFIRM_TIMEOUT`, 180 s). Interactive: countdown and the question "did the login in a new session succeed?". `auto` without a terminal: self-check. `wait`: the process returns, the wait continues.
5. After confirmation (`y`, self-check or `confirm`) the old port is closed in UFW — only rules tagged `SSH (ubuntu-bootstrap)`; foreign rules are left alone with a warning.
6. Without confirmation: rollback — previous config, sshd restart, the new port removed from UFW. A reboot inside this window is handled by the recover service.

## Logs and history

| What | Where |
|---|---|
| Full run log (every command and its output, answers, written files) | `/var/log/ubuntu-bootstrap/<RUN_ID>.log` (mode 600) |
| Events (start, finish, rollback, confirmation) | `journalctl -t ubuntu-bootstrap` |
| Change journal and backups | `ubuntu-bootstrap history <RUN_ID>` |
| Module state | `/var/lib/ubuntu-bootstrap/modules/<module>.env` |

Secrets stay out of the log: passwords are set through `passwd` on the terminal or from a hash, and the dry-run diff masks lines containing `PASSWORD`, `TOKEN`, `SECRET`, `PrivateKey`.

## Completion

`install.sh` installs `/etc/bash_completion.d/ubuntu-bootstrap`: commands, `config` subcommands, modules for `--only/--skip`, profiles for `--profile`, option names for `--set`, run ids for `rollback` and `history`. Effective after a new shell login.
