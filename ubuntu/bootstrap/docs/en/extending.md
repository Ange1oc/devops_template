# Extending

## A custom module

A file `/etc/ubuntu-bootstrap/modules.d/<name>.sh` (on a production server) or `modules/<name>.sh` (in the repository). Name: lower-case letters, digits and hyphens, up to 32 characters. No registration — the file is picked up on the next run. An additional module directory can be given with the `UBB_MODULE_PATH` variable.

```bash
# shellcheck shell=bash
MOD_SUMMARY='node_exporter for Prometheus'
MOD_GROUP=services
MOD_DEPS=(base)            # hard dependencies, enabled automatically
MOD_AFTER=(firewall)       # ordering relative to other enabled modules

mod_options() {
    opt NODE_EXPORTER_PORT port 9100 'node_exporter port'
    opt NODE_EXPORTER_FROM cidrs '' 'Allowed sources (empty: anywhere)' adv
}

mod_check() {
    svc_active prometheus-node-exporter && port_listening "$(cfg NODE_EXPORTER_PORT)"
}

mod_apply() {
    apt_install prometheus-node-exporter || return 1
    undo systemctl restart prometheus-node-exporter
    printf 'ARGS="--web.listen-address=:%s"\n' "$(cfg NODE_EXPORTER_PORT)" | file_write /etc/default/prometheus-node-exporter 644
    [[ $FILE_CHANGED == 1 ]] && { run systemctl restart prometheus-node-exporter || return 1; }
    svc_enable_now prometheus-node-exporter
}

mod_verify() { mod_check; }

mod_audit() {
    port_listening "$(cfg NODE_EXPORTER_PORT)" && check_ok 'node_exporter is listening' || check_warn 'node_exporter is not listening'
}
```

Check it with `ubuntu-bootstrap modules node-exporter`, `ubuntu-bootstrap plan --only node-exporter`, `ubuntu-bootstrap apply --only node-exporter`.

## Module contract

| Element | Purpose |
|---|---|
| `MOD_SUMMARY` | one line: what the module does (shown by `modules`, the wizard, the summary) |
| `MOD_GROUP` | `security`, `system`, `services`, `access` or your own group |
| `MOD_DEPS=(…)` | hard dependencies: enabled automatically and run earlier |
| `MOD_AFTER=(…)` | soft ordering: after the listed modules when they are enabled too |
| `MOD_DEFAULT=1` | part of the default set (when no profile is given) |
| `MOD_ALWAYS=1` | runs on every `apply` even when already applied (like preflight) |
| `MOD_CONTAINER=0` | skipped inside containers |
| `mod_options` | option declarations via `opt` |
| `mod_check` | 0 when the desired state is reached. Used by `status` and to skip the module on `apply`; must not change the system or use the network |
| `mod_apply` | idempotent apply; all changes through `file_write`, `file_set_block`, `file_remove`, `run`, with undo commands via `undo` |
| `mod_verify` | post-apply check; a failure rolls the module back. Returns 0 by default |
| `mod_audit` | checks for `audit` via `check_ok/warn/fail/info` |
| `mod_wizard` | hints before the wizard's questions and defaults via `wiz_default` (optional) |
| `mod_confirmed` | run by the `confirm` command after this module's risky change is confirmed (optional) |

Module order: `MOD_DEPS` and `MOD_AFTER` edges first; ties go to the canonical order of built-in modules, then custom modules alphabetically.

### Return codes of `mod_apply`

| Code | Meaning | What the runner does |
|---|---|---|
| 0 | applied | `mod_verify`, state `applied` |
| 3 (`$E_REFUSED`) | stopped by a guard or a confirmation was refused | rollback of the module's records, state `refused`, the run stops |
| 4 (`$E_ROLLED_BACK`) | the module already rolled itself back (timer/refusal in `confirm_or_rollback`) | state already `rolled_back`, the run stops |
| anything else | error | rollback of the module's records, state `failed`, the run stops |

`--keep-going` turns the stop into a move to the next module.

### Rules of a good module

- Every guard (`guard_refuse`) and confirmation (`confirm_danger`) goes at the top of `mod_apply`, before the first change.
- Every change not made by `file_write` is preceded by an `undo`: `undo systemctl restart X` before writing X's config, `undo userdel -r u` before `useradd`.
- External commands only through `run`: it gives logging, dry-run and SIGHUP protection.
- Dry-run: `file_write`, `run`, `undo`, `file_remove`, `file_set_block`, `confirm_danger`, `confirm_or_rollback` honour `DRY_RUN` themselves; direct calls (`chown`, `install -d`) must be wrapped in `((DRY_RUN)) ||`.
- `mod_check` must be fast and pure: read files and service state, no network.
- Generate file contents with a `*_render` function so `mod_check` can compare the file with the expectation (`[[ $(cat "$f") == "$(x_render)" ]]`) and unit tests can check the rendering.
- Files changed by external tools get a `file_snapshot` before the call.
- Comments in files read by `ufw` must be ASCII only.

## Helper API

### Options and configuration

| Function | Purpose |
|---|---|
| `opt NAME TYPE DEFAULT HELP [adv]` | declare an option (only in `mod_options`); types: `bool int port portkeep string list enum:a,b user users path size email duration timezone hostname hostnames keys ports cidrs` |
| `cfg NAME` | effective value |
| `cfg_bool NAME` | 0 when the value is true |
| `cfg_list NAME ARRAY` | list into an array (separators: comma, semicolon, space) |
| `wiz_default NAME VALUE` | wizard default when the option is not set yet (in `mod_wizard`) |
| `module_enabled NAME` | the module is in the current set |
| `module_applied NAME` | the module is in state `applied` |

### Files and commands

| Function | Purpose |
|---|---|
| `file_write PATH [MODE] [OWNER]` | stdin → file atomically with backup and journal; `FILE_CHANGED` = 1/0 |
| `file_set_block PATH MARKER [MODE]` | the `# BEGIN MARKER … # END MARKER` block inside a foreign file; empty stdin removes it |
| `file_remove PATH` | remove with backup |
| `file_snapshot PATH` | back up a file before an external command |
| `file_fix_perms PATH MODE [OWNER]` | mode and owner only |
| `run CMD...` | execute with logging (dry-run prints) |
| `undo CMD...` | undo command; may be a module function |
| `write_atomic PATH [MODE] [OWNER]` | low-level atomic write without the journal (for files outside a transaction) |
| `make_tmp_dir` | temporary directory, removed on exit |

### Packages and services

| Function | Purpose |
|---|---|
| `apt_install PKG...` | only missing packages, `--no-install-recommends`, `pkg=version` pins |
| `apt_remove PKG...` | remove installed ones |
| `apt_upgrade [--autoremove]` | `update` + `upgrade` |
| `apt_update [--force]` | once per run |
| `apt_repo_add NAME URL SUITE COMPONENTS KEY_URL FPR` | deb822 source with key fingerprint verification |
| `apt_wait [SECONDS]` | wait for dpkg to be free |
| `pkg_installed PKG` | installed? |
| `fetch_url URL DEST` | HTTPS download with retries |
| `snap_usable`, `snap_install NAME [ARGS]` | snap |
| `svc_exists/active/enabled UNIT` | unit state |
| `svc_enable_now UNIT` | `enable --now` unless already |
| `svc_dropin UNIT NAME` | drop-in from stdin with `daemon-reload` on change |
| `svc_daemon_reload` | `systemctl daemon-reload` via `run` |
| `sshd_apply OLD_PORTS` | validate and apply the sshd config, aware of socket activation |

### Facts and users

`F_OS_ID`, `F_OS_VERSION`, `F_OS_CODENAME`, `F_PRETTY`, `F_ARCH`, `F_KERNEL`, `F_HAS_SYSTEMD`, `F_VIRT`, `F_CONTAINER`, `F_MEM_MB`, `F_SWAP_MB`, `F_CPUS`, `F_DISK_FREE_GB`, `F_ROOT_FS`, `F_DEFAULT_IFACE`, `F_PRIMARY_IP`, `F_HOSTNAME`, `F_REBOOT_REQUIRED`, `F_SSH_CLIENT_IP`, `F_SSH_SERVER_PORT`, `F_SSH_USER`, `F_SSHD_PORTS`.

| Function | Purpose |
|---|---|
| `sshd_effective KEY`, `sshd_effective_ports` | values from `sshd -T` |
| `port_listening PORT [udp]` | something listens on the port |
| `user_exists U`, `user_home U`, `user_has_keys U`, `user_in_group U G`, `user_sudo_usable U`, `user_password_state U`, `human_users` | users (planned facts included in dry-run) |
| `plan_mark user:U` / `keys:U` / `sudo:U` | record a planned fact in dry-run |
| `ufw_active`, `sshd_socket_activated`, `public_ip` | environment |

### Guards, confirmations, dialogue

| Function | Purpose |
|---|---|
| `guard_refuse MSG` | guard; returns 3 (or 0 with a warning under `--force`). Idiom: `guard_refuse '…' \|\| return` |
| `confirm_danger MSG` | dangerous action; 1 on refusal. Idiom: `confirm_danger '…' \|\| return "$E_REFUSED"` |
| `confirm_or_rollback MODULE TIMEOUT MODE QUESTION SELFCHECK_FN` | rollback timer and confirmation; returns 0, 3 or 4 |
| `ask_yn Q [y\|n]`, `ask_input VAR PROMPT DEFAULT [VALIDATOR]`, `ask_choice VAR TITLE DEFAULT ITEM...`, `ask_secret VAR PROMPT` | questions (defaults without a terminal) |
| `interactive` | a terminal is available |
| `log_info/ok/warn/error/title/plain/debug` | output; `log_warn` lands in the final summary |
| `die MSG`, `die_code CODE MSG`, `die_usage MSG` | terminate |

### Audit

`check_ok DESC [HINT]`, `check_warn DESC [HINT]`, `check_fail DESC [HINT]`, `check_info DESC [HINT]`. The module of the check is filled in automatically.

### Validation

`is_uint is_port is_bool is_username is_abs_path is_size is_email is_duration is_timezone is_ipv4 is_ipv6 is_ip is_cidr is_ip_or_cidr is_hostname is_port_spec is_ssh_pubkey is_name is_opt_name is_git_ref is_github_repo to_bool`, plus `in_list X LIST...`, `split_list STR ARRAY`, `join_by SEP ITEMS...`, `json_str STR`, `size_to_mb SIZE`, `sha256_str STR`.

## A custom profile

A file `/etc/ubuntu-bootstrap/profiles.d/<name>.conf`:

```
# Backend server: minimal + docker, no swap
MODULES=preflight,base,time,users,ssh,firewall,fail2ban,updates,journald,sysctl,limits,docker
FW_DOCKER_PROTECT=yes
SSH_PORT=2222
UPD_ORIGINS=all
```

The first comment line is the description shown by `profiles` and the wizard. A profile supplies defaults; the configuration file and `--set` override them. A custom profile named like a built-in one takes precedence.

## A custom command

A file `commands/<name>.sh`:

```bash
# shellcheck shell=bash
CMD_SUMMARY='what it does'
CMD_GROUP=inspect        # setup | run | inspect | maintenance
CMD_ROOT=0               # 1 (default) requires root

cmd_usage() { echo 'Usage: ubuntu-bootstrap <name> [arguments]'; }

cmd_run() {
    config_load          # when options are needed
    runner_select        # when the module set is needed (SELECTED_MODULES)
    ...
}
```

The command receives the global options already parsed (`OPT_*`, `DRY_RUN`, `SET_OVERRIDES`) and the loaded module registry (`MOD_ALL`, `MOD_*_OF`).

## Testing a custom module

- Rendering and logic: in `tests/unit.sh` inside the sandbox (`UBB_SYSROOT`): load the module with `module_load`, set `CONF[...]`, check the `*_render` output.
- Behaviour: a scenario in `tests/e2e.sh`: a systemd container, `install_tool`, `ubb "$box" apply --only <name> --yes`, checks via `boxq`. The `scn_failures` and `scn_interrupt` scenarios show how to drop test modules into `/etc/ubuntu-bootstrap/modules.d/`.
- `tests/run.sh lint` runs shellcheck over `modules/*.sh`.
