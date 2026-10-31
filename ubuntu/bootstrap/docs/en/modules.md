# Modules

A module is a file `modules/<name>.sh`. It declares options, knows how to tell whether the desired state is already reached (`mod_check`), how to apply it idempotently (`mod_apply`), how to verify the result (`mod_verify`) and which checks to contribute to `audit` (`mod_audit`). Execution order follows dependencies (`MOD_DEPS` are enabled automatically) and soft ordering (`MOD_AFTER`): `preflight → base → time → users → ssh → firewall → fail2ban → updates → sysctl → limits → swap → journald → docker → nginx → certbot → git → wg-network`.

Notation in the option tables: **adv** — an advanced option, asked by the wizard only with `--advanced`. An empty default is shown as "—".

Every file the tool writes contains `ubuntu-bootstrap` in its name or lives in a block between `# BEGIN ubuntu-bootstrap ...` / `# END ubuntu-bootstrap ...` markers inside a foreign file. Foreign files are never rewritten as a whole.

---

## preflight — server checks

Runs first on every `apply` and `plan` (`MOD_ALWAYS=1`), even when not in the set (an explicit `--skip preflight` disables it).

| Option | Type | Default | Purpose |
|---|---|---|---|
| `PREFLIGHT_MIN_DISK_GB` | int | 2 | minimum free space on `/` in GiB (adv) |

What it does:

- guards: the OS must be Ubuntu 22.04/24.04/26.04 (otherwise code 3, `--force` lifts), free space on `/` not below the minimum;
- warnings: architecture other than amd64/arm64, no systemd, running inside a container (swap, kernel sysctl, snap will be skipped);
- waits up to 120 seconds for apt/dpkg to become free (unattended-upgrades may hold the lock right after boot);
- prints a summary: OS, kernel, virtualization, CPU/RAM/swap, free space, interface and IP, hostname, current SSH session (user, client address, port) and sshd ports, listening ports with their processes, versions of already installed nginx/docker/ufw/fail2ban/certbot/wg-network.

Changes nothing.

---

## base — packages, upgrade, hostname, timezone

Dependencies: preflight.

| Option | Type | Default | Purpose |
|---|---|---|---|
| `BASE_UPGRADE` | bool | yes | `apt-get update && apt-get upgrade` before installing packages |
| `BASE_PACKAGES` | list | ca-certificates,curl,gnupg,git,jq,rsync,unzip,htop,ncdu,bind9-dnsutils,openssl,needrestart,logrotate | base packages (adv) |
| `BASE_EXTRA_PACKAGES` | list | — | additional packages |
| `BASE_TIMEZONE` | timezone | — | timezone; empty keeps the current one |
| `BASE_HOSTNAME` | hostname | — | hostname; empty keeps the current one |
| `BASE_AUTOREMOVE` | bool | yes | run `autoremove --purge` after the upgrade (adv) |

What it does:

- `apt-get upgrade` non-interactively (`DEBIAN_FRONTEND=noninteractive`, `--force-confdef --force-confold`: existing package configs are never replaced by prompts; `NEEDRESTART_MODE=l` makes needrestart list services instead of restarting them);
- installs missing packages with `--no-install-recommends`;
- timezone via `timedatectl set-timezone` (undo command: the previous zone);
- hostname via `hostnamectl set-hostname` (undo command: the previous name) plus a `127.0.1.1 <hostname> <short name>` entry in the `# BEGIN ubuntu-bootstrap hostname` block of `/etc/hosts`, otherwise `sudo` complains about an unresolvable name;
- warns when a reboot is required after the upgrade (`/var/run/reboot-required`).

"Applied" means: all packages installed, timezone and hostname match. A later run with `BASE_UPGRADE=yes` runs `apt-get upgrade` again only when the module is re-executed (options changed, `--reapply` or the check failed).

Audit: base packages installed, hostname resolves.

---

## time — time synchronization

Dependencies: preflight. Skipped inside containers: `systemd-timesyncd` and `chrony` carry `ConditionVirtualization=!container`, the host owns the clock.

| Option | Type | Default | Purpose |
|---|---|---|---|
| `TIME_DAEMON` | enum: auto, chrony, timesyncd | auto | `auto` keeps the installed daemon (Ubuntu 26.04 ships chrony with NTS by default, older releases timesyncd); timesyncd when none is installed |
| `TIME_SERVERS` | list | — | custom NTP servers; empty uses the distribution or provider defaults (adv) |

What it does: installs the chosen daemon (chrony replaces timesyncd on install), with servers given writes `/etc/chrony/sources.d/ubuntu-bootstrap.sources` (`server X iburst`) or `/etc/systemd/timesyncd.conf.d/ubuntu-bootstrap.conf` (`[Time] NTP=...`) and restarts the daemon, enables it and runs `timedatectl set-ntp true`.

State: the daemon is installed and active, `timedatectl` reports `NTP=yes`. Audit: `NTPSynchronized=yes`.

---

## users — administrator

Dependencies: preflight. The `ssh` module runs after it and relies on the created user in its guards.

| Option | Type | Default | Purpose |
|---|---|---|---|
| `ADMIN_USER` | user | — | administrator name; empty means the module does nothing |
| `ADMIN_SSH_KEYS` | keys | — | public keys separated by `;` |
| `ADMIN_SSH_KEYS_GITHUB` | list | — | GitHub logins: keys are fetched from `https://github.com/<login>.keys` over TLS and tagged with the comment `github:<login>` |
| `ADMIN_COPY_ROOT_KEYS` | enum: auto, yes, no | auto | copy root's `authorized_keys` to the administrator; `auto` only when no other keys are configured and the user has none yet |
| `ADMIN_SUDO` | bool | yes | add to the `sudo` group |
| `ADMIN_SUDO_MODE` | enum: password, nopasswd | password | `password` — sudo asks for the user's password; `nopasswd` — `NOPASSWD:ALL` via `/etc/sudoers.d/` (requires confirmation) |
| `ADMIN_PASSWORD_HASH` | string | — | crypt hash (`mkpasswd -m sha-512`) for the `password` mode without a terminal (adv) |
| `ADMIN_SHELL` | path | /bin/bash | login shell (adv) |
| `ADMIN_GROUPS` | list | — | extra groups; missing ones are skipped with a warning (adv) |

What it does:

1. With `ADMIN_SUDO_MODE=nopasswd` and no sudoers file yet, asks for confirmation **before any change** ("a compromised SSH key equals instant root"); a refusal leaves the system untouched.
2. Creates the user with `useradd -m -s SHELL -U` (undo: `userdel -r`) and locks the password (`passwd -l`): key-only login. An existing user is not recreated; a system user (UID < 1000) produces a warning.
3. Collects keys: explicit, GitHub, and root's keys when applicable. Appends only missing keys to `~/.ssh/authorized_keys` (compared by key body) and keeps existing lines. Permissions: `~/.ssh` 700, the file 600, owned by the user.
4. Without keys it warns that SSH login will be impossible after hardening (the `ssh` module will then refuse to disable passwords).
5. Groups: `usermod -aG` with undo `gpasswd -d`.
6. sudo: the `sudo` group; for `nopasswd` the file `/etc/sudoers.d/90-ubuntu-bootstrap-<user>` with mode 440, checked with `visudo -cf` (an invalid file is an error and a rollback). For `password`: when no password is set, it is taken from `ADMIN_PASSWORD_HASH` (`chpasswd -e`) or asked on the terminal (`passwd`); without either the module warns that sudo will not work and the `ssh` module will not disable root key login.

State: the user exists, sudo is usable (password set or NOPASSWD), and with configured keys the user has `authorized_keys`.

Audit: number of regular users, administrator exists, has keys, sudo works, `~/.ssh` permissions.

Files: `/home/<user>/.ssh/authorized_keys`, `/etc/sudoers.d/90-ubuntu-bootstrap-<user>`.

---

## ssh — SSH hardening

Dependencies: preflight; after users. The most sensitive module: all guards run before any change and the apply is protected by a rollback timer.

| Option | Type | Default | Purpose |
|---|---|---|---|
| `SSH_PORT` | portkeep | keep | port; `keep` leaves it alone (no `Port` directive is written) |
| `SSH_PASSWORD_AUTH` | bool | no | allow password login; `no` also disables `KbdInteractiveAuthentication` |
| `SSH_PERMIT_ROOT` | enum: auto, no, prohibit-password, yes | auto | `auto` → `no` when a non-root user with a key **and working sudo** exists, otherwise `prohibit-password`; `yes` requires confirmation |
| `SSH_ALLOW_USERS` | users | — | `AllowUsers`; empty writes no directive. The wizard proposes `ADMIN_USER` |
| `SSH_CONFIRM` | enum: auto, wait, none | auto | how to confirm access after apply (see below); `none` only with `--force` |
| `SSH_CONFIRM_TIMEOUT` | int | 180 | seconds until automatic rollback |
| `SSH_MAX_AUTH_TRIES` | int | 4 | `MaxAuthTries` (adv) |
| `SSH_LOGIN_GRACE` | int | 30 | `LoginGraceTime` (adv) |
| `SSH_CLIENT_ALIVE_INTERVAL` | int | 300 | `ClientAliveInterval`; `ClientAliveCountMax` is always 3 (adv) |
| `SSH_X11_FORWARDING` | bool | no | `X11Forwarding` (adv) |
| `SSH_AGENT_FORWARDING` | bool | no | `AllowAgentForwarding` (adv) |
| `SSH_TCP_FORWARDING` | bool | yes | `AllowTcpForwarding`, needed by tunnels and VS Code Remote (adv) |
| `SSH_LOG_LEVEL` | enum: INFO, VERBOSE | VERBOSE | `VERBOSE` logs key fingerprints, useful for audit and fail2ban (adv) |
| `SSH_CLOSE_OLD_PORT` | bool | yes | close the old port in UFW after confirmation (adv) |

File `/etc/ssh/sshd_config.d/00-ubuntu-bootstrap.conf` (mode 600). The `00-` prefix matters: sshd applies the **first** value of a directive it meets, and `Include sshd_config.d/*.conf` sits at the top of `sshd_config`, so these values win over cloud-init (`50-cloud-init.conf`) and the main file. Contents:

```
Port <port>                      only when SSH_PORT != keep
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no  only when passwords are disabled
PermitEmptyPasswords no
PermitRootLogin <value>
MaxAuthTries 4
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 3
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding yes
LogLevel VERBOSE
UseDNS no
AllowUsers ...                   only when set
```

Guards (code 3; `--force` lifts):

- `sshd_config` must contain `Include /etc/ssh/sshd_config.d/*.conf`, otherwise the file would never be read;
- `SSH_CONFIRM=none` is refused without `--force`;
- passwords are disabled only when at least one allowed user (honouring `AllowUsers` and `PermitRootLogin`) has `authorized_keys`;
- `PermitRootLogin no` only when a non-root user with a key and working sudo exists (otherwise the server loses its administrator);
- `AllowUsers` may not exclude the user of the current SSH session (for root with `PermitRootLogin no` only a warning: the current session keeps working);
- the new port must not be used by another service; a port below 1024 produces a warning.

`PermitRootLogin yes` requires confirmation (`confirm_danger`).

Apply:

1. When the port changes and UFW is active, the new port is opened in UFW before sshd restarts (`limit` when the firewall module is enabled or applied with `FW_SSH_LIMIT=yes`, otherwise `allow`) with the comment `SSH (ubuntu-bootstrap)`.
2. The undo command (re-applying the previous config) is registered, the file is written, `sshd -t` validates it. An invalid config is an error: the file is rolled back and sshd is not restarted.
3. Restart: on Ubuntu 22.10+ sshd is socket-activated and the generator reads ports at `daemon-reload`, so a port change runs `systemctl daemon-reload` and `restart ssh.socket` (a plain `reload` does not change the port, Launchpad #2069041); without a port change `reload-or-restart ssh.service`. Existing sessions survive the restart (`KillMode=process`). Then the module verifies that sshd listens on every expected port and `sshd -T` shows the configured values.
4. Access confirmation (`confirm_or_rollback`):
   - a rollback timer is armed outside the SSH session (`systemd-run --on-active`); `/var/lib/ubuntu-bootstrap/pending.env` records what to roll back;
   - **interactive**: a countdown and the question "did the login in a new session succeed?"; a ready-made `ssh -p PORT USER@IP` command is printed. `y` confirms, `n` or the timeout rolls back. `confirm` from another session counts too;
   - **`auto` without a terminal**: after 2 seconds a self-check — sshd answers with an `SSH-2.0` banner on the new port via `127.0.0.1` and the port is allowed in UFW (when UFW is active). Success confirms, failure rolls back;
   - **`wait`**: the process exits 0, the timer keeps running; `confirm` from a new session cancels it, otherwise rollback;
   - **`none`**: no timer (only with `--force`).
5. After confirmation old ports are closed: only UFW rules with the comment `SSH (ubuntu-bootstrap)` for ports sshd no longer listens on are removed. Open ports without the tag produce a warning. In `wait` mode this is done by the `confirm` command (the `mod_confirmed` hook).

Rollback of the module (on error, timer, refusal or `rollback`): the previous file is restored (or the created one removed), the sshd config is re-applied with a socket restart when needed, the new port is removed from UFW.

State: the file matches the expected content, `sshd -T` shows the configured `passwordauthentication`, `permitrootlogin`, `port`, `maxauthtries`. `sshd -T` is the source of truth rather than file parsing, so every included config counts. `without-password` is normalized to `prohibit-password`.

Audit: passwords, root, `MaxAuthTries ≤ 4`, `X11Forwarding`, `PermitEmptyPasswords`, ports and `LogLevel`, host key permissions, an obsolete DSA key.

---

## firewall — UFW

Dependencies: preflight; after ssh and docker (to know the target SSH port and whether Docker is present).

| Option | Type | Default | Purpose |
|---|---|---|---|
| `FW_SSH_LIMIT` | bool | yes | SSH via `ufw limit`: at most 6 new connections per 30 seconds from one IP |
| `FW_SSH_FROM` | cidrs | — | allow SSH only from these addresses; empty means from anywhere |
| `FW_WEB` | enum: auto, yes, no | auto | open 80/tcp and 443/tcp; `auto` when the nginx module is enabled or nginx is installed |
| `FW_HTTP3` | bool | yes | also 443/udp (adv) |
| `FW_ALLOW_PORTS` | ports | — | extra ports, e.g. `8443/tcp,51820/udp` (tcp when no protocol is given) |
| `FW_DOCKER_PROTECT` | enum: auto, yes, no | auto | block external access to containers through the `DOCKER-USER` chain; `auto` when the docker module is enabled or docker is installed |
| `FW_DOCKER_ALLOW_PORTS` | ports | — | container ports reachable from outside despite the protection (adv) |
| `FW_LOGGING` | enum: off, low, medium | low | `ufw logging` (adv) |
| `FW_CONFIRM` | enum: auto, wait, none | auto | access confirmation after enabling UFW, as for ssh; `none` only with `--force` (adv) |
| `FW_CONFIRM_TIMEOUT` | int | 180 | seconds until rollback (adv) |

Desired rules: SSH ports (the ssh module's target port when it is enabled and changes the port, otherwise the current sshd ports) as `limit` or `allow`, or `allow from CIDR` for every address in `FW_SSH_FROM`; 80/443 with `FW_WEB`; 443/udp with `FW_HTTP3`; `FW_ALLOW_PORTS`. Rules are tagged with the comment `ubuntu-bootstrap` (SSH: `SSH (ubuntu-bootstrap)`), which lets the ssh module tell its own rules from foreign ones later.

Guards and confirmations (before any change): `FW_SSH_FROM` must include the IP of the current SSH session; enabling an inactive UFW requires confirmation listing the ports to be opened; `FW_CONFIRM=none` with a remote session needs `--force`. Inside a container without `NET_ADMIN` the module is skipped with a warning.

Apply:

- the undo command is registered (return UFW to its previous enabled/disabled state and reload), snapshots of `user.rules`, `user6.rules`, `ufw.conf`, `after.rules`, `after6.rules` are taken;
- `default deny incoming`, `default allow outgoing`, `logging`; only missing rules are added (checked against `ufw status`), existing foreign rules are never removed;
- Docker protection: `/etc/ufw/after.rules` (mode 640) gets a `*filter` table with the `DOCKER-USER` chain between the markers `# BEGIN ubuntu-bootstrap docker` and `# END`: on the external interface (the default-route interface) `RELATED,ESTABLISHED` and explicitly allowed ports (matched by original destination port, `--ctorigdstport`, i.e. before DNAT) pass, every other new connection is dropped; containers stay reachable from localhost and docker networks. Docker leaves foreign rules in `DOCKER-USER` alone and `ufw reload` reinstalls them. Comments inside the block are ASCII only: ufw rewrites its files in ASCII;
- when UFW was already active: `ufw reload` on changes, no confirmation needed;
- when UFW was disabled: `ufw --force enable`, `ufw status verbose` is printed; with a remote SSH session `confirm_or_rollback` runs with the self-check "UFW is active and the SSH ports are allowed"; from a local console no confirmation is needed.

Rollback: the rule files are restored from the snapshots and UFW returns to its previous state.

State: UFW is active, every desired rule is present, the DOCKER-USER block is present (or absent) according to `FW_DOCKER_PROTECT`.

Audit: UFW active, default deny incoming, SSH ports allowed, DOCKER-USER protection when Docker is installed, rule count.

---

## fail2ban

Dependencies: preflight; after ssh and firewall.

| Option | Type | Default | Purpose |
|---|---|---|---|
| `F2B_MAXRETRY` | int | 5 | failed attempts before a ban |
| `F2B_FINDTIME` | duration | 10m | window for counting attempts |
| `F2B_BANTIME` | duration | 1h | ban duration |
| `F2B_INCREMENT` | bool | yes | `bantime.increment`: repeat offenders get doubled bans, up to 1 week (adv) |
| `F2B_IGNOREIP` | cidrs | — | never ban these |
| `F2B_IGNORE_CURRENT` | bool | yes | add the IP of the current SSH session to `ignoreip` (adv) |

File `/etc/fail2ban/jail.d/ubuntu-bootstrap.local`:

```
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 <F2B_IGNOREIP> <current session IP>
bantime, findtime, maxretry, bantime.increment, bantime.maxtime = 1w

[sshd]
enabled = true
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd + _COMM=sshd-session
port = <sshd ports, comma-separated>
mode = aggressive
```

Why: on Ubuntu 24.04+ `auth.log` may be absent, so the systemd journal is read. `journalmatch` explicitly covers the `ssh.service` unit (its name on Ubuntu) and the `sshd`/`sshd-session` processes (OpenSSH 9.8+ moved session handling into a separate process). `backend=systemd` needs `python3-systemd`, which is only a recommended package on 22.04, so it is installed explicitly. The port comes from `sshd -T`: after an SSH port change the module re-applies automatically (the expected file content changes).

Apply: install, write the file, `fail2ban-client -t`, enable the service, wait for `fail2ban-client ping`, `reload` only for an already running service when the file changed, wait for the `sshd` jail. Rollback: the previous file and `reload-or-restart`.

Audit: service active, jail up, currently and totally banned, whether the jail port matches the sshd ports.

---

## updates — automatic updates

Dependencies: preflight.

| Option | Type | Default | Purpose |
|---|---|---|---|
| `UPD_ORIGINS` | enum: security, all | security | `security` — the security pocket only (Ubuntu's default); `all` — also `-updates` |
| `UPD_AUTO_REBOOT` | bool | no | reboot when an update requires it |
| `UPD_REBOOT_TIME` | string | 04:00 | reboot time (local) (adv) |
| `UPD_REMOVE_UNUSED` | bool | yes | remove unused dependencies and old kernels (adv) |
| `UPD_SCHEDULE` | string | — | custom `OnCalendar` for the `apt-daily` and `apt-daily-upgrade` timers, e.g. `Sun *-*-* 04:00`; empty keeps Ubuntu's daily schedule (adv) |
| `UPD_MAIL` | email | — | report address (needs a configured MTA) (adv) |

Files:

- `/etc/apt/apt.conf.d/52ubuntu-bootstrap-unattended`: with `all` an `Allowed-Origins` entry for `${distro_id}:${distro_codename}-updates` (security and release are already in the `50unattended-upgrades` defaults); `Automatic-Reboot`, `Automatic-Reboot-WithUsers "false"`, `Automatic-Reboot-Time`, `Remove-Unused-Dependencies`, `Remove-Unused-Kernel-Packages`, `Remove-New-Unused-Dependencies "true"`, `MinimalSteps "true"`, `SyslogEnable "true"`, with `UPD_MAIL` also `Mail` and `MailReport "on-change"`;
- `/etc/apt/apt.conf.d/20auto-upgrades`: `Update-Package-Lists "1"`, `Unattended-Upgrade "1"`, `AutocleanInterval "7"`;
- with `UPD_SCHEDULE`: drop-ins `apt-daily.timer.d/ubuntu-bootstrap.conf` (`RandomizedDelaySec=10m`) and `apt-daily-upgrade.timer.d/ubuntu-bootstrap.conf` (`30m`); the schedule is validated with `systemd-analyze calendar`. Without the option the drop-ins are removed.

After writing, the configuration is validated with `apt-config dump`; the timers are enabled and restarted (outside containers).

Audit: package installed, `APT::Periodic::Unattended-Upgrade` not 0, timer active and its next run, reboot policy, last log entry.

---

## sysctl — kernel parameters

Dependencies: preflight.

| Option | Type | Default | Purpose |
|---|---|---|---|
| `SYSCTL_HARDENING` | bool | yes | network hardening and filesystem/kernel protection |
| `SYSCTL_PERFORMANCE` | bool | yes | network and filesystem performance |
| `SYSCTL_BBR` | bool | yes | TCP BBR + fq |
| `SYSCTL_IP_FORWARD` | enum: auto, on, off | auto | `auto` disables forwarding unless Docker or WireGuard is present (enabled docker module, `docker`/`wg` commands, `/etc/wireguard`) (adv) |
| `SYSCTL_IPV6` | enum: keep, disable | keep | `disable` turns IPv6 off (adv) |

Files:

- `/etc/sysctl.d/90-ubuntu-bootstrap-hardening.conf` (CIS Ubuntu Benchmark L1, Network Parameters): `tcp_syncookies=1`, `rp_filter=1`, `accept_redirects=0`, `secure_redirects=0`, `send_redirects=0`, `accept_source_route=0`, `log_martians=1`, `icmp_echo_ignore_broadcasts=1`, `icmp_ignore_bogus_error_responses=1`, for IPv6 `accept_redirects=0`, `accept_source_route=0`, `accept_ra=0`; `fs.protected_symlinks/hardlinks=1`, `protected_fifos/regular=2`, `fs.suid_dumpable=0`, `kernel.kptr_restrict=1`, `kernel.dmesg_restrict=1`, `kernel.randomize_va_space=2`, `kernel.yama.ptrace_scope=1`; `ip_forward=0` and `ipv6 forwarding=0` when forwarding is not needed; `disable_ipv6=1` with `SYSCTL_IPV6=disable`;
- `/etc/sysctl.d/91-ubuntu-bootstrap-performance.conf`: `somaxconn=4096`, `tcp_max_syn_backlog=8192`, `netdev_max_backlog=16384`, `ip_local_port_range=1024 65535`, `tcp_fin_timeout=15`, `tcp_tw_reuse=1`, keepalive 600/30/5, `tcp_slow_start_after_idle=0`, `tcp_mtu_probing=1`, 16 MiB buffers, `fs.file-max=2097152`, inotify 524288/1024, `fs.aio-max-nr`, `vm.max_map_count=262144`, `vm.swappiness=10`, `vm.dirty_ratio=20`, `vm.dirty_background_ratio=5`; with BBR `default_qdisc=fq`, `tcp_congestion_control=bbr`;
- `/etc/modules-load.d/ubuntu-bootstrap-bbr.conf` with `tcp_bbr`.

BBR is enabled only when the kernel provides it (`tcp_available_congestion_control` or `modinfo tcp_bbr`) and the run is not inside a container; otherwise the BBR lines are not written and a warning is printed. This keeps the module idempotent on kernels without BBR.

The files are applied immediately with `sysctl -p`; inside containers some keys are read-only — individual failures are not fatal (a warning), the file applies at boot. Undo command: `sysctl --system` after the files are restored. Disabling an option removes its file.

Audit (outside containers): key values, `ip_forward` with Docker/WireGuard taken into account, current `tcp_congestion_control` and `somaxconn`.

---

## limits — file descriptor limits

Dependencies: preflight.

| Option | Type | Default | Purpose |
|---|---|---|---|
| `LIMITS_NOFILE` | int | 65535 | soft limit of open files; hard is always 524288 (systemd's default) |
| `LIMITS_NPROC` | int | 65535 | process limit (adv) |

Files: `/etc/systemd/system.conf.d/90-ubuntu-bootstrap.conf` (`DefaultLimitNOFILE=<soft>:524288`, `DefaultLimitNPROC`) and `/etc/security/limits.d/90-ubuntu-bootstrap.conf` (`*` and `root`, soft/hard nofile and nproc). `[Manager]` values are read only on `systemctl daemon-reexec`, which runs when the file changes; running services pick the limits up after their own restart, sessions after a new login.

Audit: systemd `DefaultLimitNOFILESoft`, nginx `LimitNOFILE`.

---

## swap

Dependencies: preflight. Not applied inside containers (`MOD_CONTAINER=0`).

| Option | Type | Default | Purpose |
|---|---|---|---|
| `SWAP_SIZE` | size | auto | `auto` — 2G with RAM ≤ 2 GiB, otherwise 4G; `0` — do not create; or a size such as `8G` |
| `SWAP_FILE` | path | /swapfile | file path (adv) |
| `SWAP_SWAPPINESS` | int | 10 | `vm.swappiness` (adv) |

Logic: existing swap that is not our file is left alone; a file that exists but is not active as swap is an error (sort it out manually); on ZFS swap files are unsupported — skipped with a warning; on btrfs the file is created with `chattr +C` and `dd` (not `fallocate`); free space must cover the size plus 2 GiB. Creation: `fallocate` (or `dd`), mode 600, `mkswap`, `swapon`; undo commands `swapoff` and file removal. An `/etc/fstab` entry in the `# BEGIN ubuntu-bootstrap swap` block; `/etc/sysctl.d/92-ubuntu-bootstrap-swap.conf` (`vm.swappiness`, `vm.vfs_cache_pressure=50`).

Audit: swap present, listed in fstab.

---

## journald

Dependencies: preflight. Skipped without systemd.

| Option | Type | Default | Purpose |
|---|---|---|---|
| `JOURNALD_MAX_USE` | size | 1G | `SystemMaxUse` |
| `JOURNALD_MAX_FILE` | size | 128M | `SystemMaxFileSize` (adv) |
| `JOURNALD_RETENTION` | duration | 1month | `MaxRetentionSec` (adv) |
| `JOURNALD_FORWARD_SYSLOG` | enum: auto, yes, no | auto | `ForwardToSyslog`; `auto` is yes when rsyslog is installed (adv) |

File `/etc/systemd/journald.conf.d/90-ubuntu-bootstrap.conf`: `Storage=persistent`, `Compress=yes`, the limits, `RateLimitIntervalSec=30s`, `RateLimitBurst=10000`. `/var/log/journal` is created (group `systemd-journal`, mode 2755); journald restarts when the file changes.

Audit: journal persistent and its disk usage, logrotate installed.

---

## docker — Docker CE

Dependencies: preflight, base.

| Option | Type | Default | Purpose |
|---|---|---|---|
| `DOCKER_VERSION` | string | — | `docker-ce` version (`apt-cache madison docker-ce`); empty is latest (adv) |
| `DOCKER_REMOVE_CONFLICTS` | bool | yes | remove `docker.io`, `docker-compose`, `docker-compose-v2`, `docker-doc`, `docker-buildx`, `podman-docker`, `containerd`, `runc` (docs.docker.com recommendation); requires confirmation |
| `DOCKER_USERS` | users | — | add to the `docker` group (equals root access to the host; requires confirmation; the alternative is `sudo docker`) |
| `DOCKER_LOG_MAX_SIZE` | size | 20M | container log rotation: file size (adv) |
| `DOCKER_LOG_MAX_FILE` | int | 5 | number of files (adv) |
| `DOCKER_LIVE_RESTORE` | bool | yes | containers survive a daemon restart (adv) |
| `DOCKER_NO_NEW_PRIVILEGES` | bool | no | `no-new-privileges` by default (breaks images relying on setuid) (adv) |
| `DOCKER_PRUNE_TIMER` | bool | no | weekly cleanup of unused images and build cache older than 7 days (adv) |

Apply:

1. Confirmations before any change: removing conflicting packages (running `docker.io` containers stop, data in `/var/lib/docker` is kept); adding every user to the docker group. Without `DOCKER_REMOVE_CONFLICTS` installed conflicting packages stop the module with a guard.
2. Repository: the key `https://download.docker.com/linux/ubuntu/gpg` is fetched over TLS and its fingerprint compared with the official `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88` **before** it is written to `/etc/apt/keyrings/docker.asc`; a deb822 source `/etc/apt/sources.list.d/docker.sources` (`Suites: <codename>`, `Components: stable`, `Architectures: <arch>`, `Signed-By`). A legacy `docker.list` is removed to avoid a duplicate source.
3. Packages `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin` (pinned with `DOCKER_VERSION`, availability checked first). Undo command: `systemctl disable --now docker containerd` (packages are not removed).
4. `/etc/docker/daemon.json`: `log-driver json-file`, `log-opts max-size/max-file`, `live-restore`, `no-new-privileges`, `default-ulimits nofile 65535:524288`. An existing file is **not replaced**: our keys are added only when absent (`jq`); foreign values including `data-root` and another `log-driver` are preserved. On change `systemctl restart docker` (with `live-restore` containers keep running).
5. docker group: `usermod -aG docker`, undo `gpasswd -d`; a re-login is needed.
6. Prune timer: `ubuntu-bootstrap-docker-prune.service` (`docker system prune -f --filter until=168h`, `docker builder prune`) and `.timer` (`Sun *-*-* 03:30`, `RandomizedDelaySec=30m`, `Persistent=true`).
7. Report: containers with `privileged` or a mounted `docker.sock`, ports on `0.0.0.0` (reachable from outside around UFW unless DOCKER-USER protection is in place).

Audit: daemon running, official package, log rotation, containers publishing on all interfaces or privileged, docker group members, free space in `/var/lib/docker`.

---

## nginx

Dependencies: preflight, base.

| Option | Type | Default | Purpose |
|---|---|---|---|
| `NGINX_SOURCE` | enum: ubuntu, stable, mainline | stable | `ubuntu` — the distribution package (Canonical patches, version frozen at release); `stable`/`mainline` — nginx.org |
| `NGINX_VERSION` | string | — | package version; empty is latest (adv) |
| `NGINX_SERVER_TOKENS` | bool | no | show the version in headers and error pages (adv) |
| `NGINX_SECURITY_SNIPPET` | bool | yes | create `snippets/security-headers.conf` |
| `NGINX_CLIENT_MAX_BODY` | size | 20M | `client_max_body_size` (adv) |
| `NGINX_DISABLE_DEFAULT_SITE` | bool | no | disable the default site (`sites-enabled/default` or `conf.d/default.conf`) (adv) |

Apply:

- for nginx.org: the key `https://nginx.org/keys/nginx_signing.key` (the file holds several keys, so **membership** of the official fingerprint `573B FD6B 3D8F BC64 1079 A6AB ABF5 BD82 7BD9 BF62` is checked), a deb822 source `/etc/apt/sources.list.d/nginx.sources`, the pin `/etc/apt/preferences.d/99nginx` with priority 900 (nginx.org packages are preferred over the distribution's);
- when nginx is already installed from another source, the source is not changed (different config layouts) and a warning is printed;
- `/etc/nginx/conf.d/00-ubuntu-bootstrap.conf` (`http{}` level): `server_tokens`, `client_max_body_size`, 30 s client timeouts, `keepalive_requests 1000`, TLS per the Mozilla intermediate profile (`TLSv1.2 TLSv1.3`, `ssl_prefer_server_ciphers off`, session cache/tickets), gzip, `map $http_upgrade $ubb_connection_upgrade` for WebSocket proxying;
- `/etc/nginx/snippets/security-headers.conf`: `X-Content-Type-Options nosniff`, `X-Frame-Options SAMEORIGIN`, `Referrer-Policy strict-origin-when-cross-origin`, `Permissions-Policy`; CSP and HSTS are deliberately absent (site-specific; certbot adds HSTS with `CERTBOT_HSTS`). Include it in `server{}` with `include snippets/security-headers.conf;`;
- drop-in `nginx.service.d/ubuntu-bootstrap.conf` with `LimitNOFILE=65535`;
- `nginx -t` before enabling; `reload` on changes; undo command: `reload` when the config is valid.

Audit: config valid, service active, `server_tokens off`, no TLSv1/1.1, site count.

---

## certbot — Let's Encrypt

Dependencies: preflight; after nginx and firewall.

| Option | Type | Default | Purpose |
|---|---|---|---|
| `CERTBOT_METHOD` | enum: auto, snap, apt | auto | snap is the EFF recommendation and always current; `auto` picks snap when snapd works (not inside containers), otherwise apt |
| `CERTBOT_DOMAINS` | hostnames | — | domains; the first is primary; empty only installs certbot |
| `CERTBOT_EMAIL` | email | — | expiry notifications; empty means `--register-unsafely-without-email` |
| `CERTBOT_REDIRECT` | bool | yes | HTTP → HTTPS redirect |
| `CERTBOT_HSTS` | bool | no | HSTS header (adv) |
| `CERTBOT_STAGING` | bool | no | the staging ACME server: no rate limits, untrusted certificate (adv) |
| `CERTBOT_DNS_CHECK` | bool | yes | before issuing, verify that the A records point at this server (adv) |

Apply:

1. Installation: snap (`snapd`, `snap install core`, `snap install --classic certbot`, symlink `/usr/bin/certbot`) or apt (`certbot python3-certbot-nginx`).
2. Without domains the module stops here. Issuing needs nginx (`--nginx`).
3. If a certificate for the primary domain exists, only `certbot renew --dry-run` runs.
4. DNS guard: every domain must resolve to the server's public IP (determined via `api.ipify.org`, falling back to the default-route interface IP); otherwise code 3 (`CERTBOT_DNS_CHECK=no` disables). A warning when nothing listens on port 80.
5. When nginx has no `server_name` with the primary domain, a minimal HTTP site is created as `sites-available/<domain>.conf` (plus a `sites-enabled` link) or `conf.d/<domain>.conf`, so certbot can pass HTTP-01 and add TLS to it.
6. `certbot --nginx -d ... --agree-tos --no-eff-email --non-interactive --keep-until-expiring` with `--redirect/--no-redirect`, `--hsts`, `--staging`; then `certbot renew --dry-run`. A snapshot of the site config is taken first; the undo command is an nginx `reload`.

Audit: renewal timer (`certbot.timer` or `snap.certbot.renew.timer`), days left for every certificate (warning under 14 days).

---

## git — deploy keys

Dependencies: preflight, base; after users.

| Option | Type | Default | Purpose |
|---|---|---|---|
| `GIT_HOSTS` | hostnames | — | `github.com`, `gitlab.com`, `bitbucket.org`, a custom host; empty means the module is not needed |
| `GIT_USER` | user | — | key owner; empty means `ADMIN_USER`, else root (adv) |
| `GIT_CHECK` | bool | no | run `ssh -T git@host` afterwards (the key must already be added to the repository) (adv) |

For every host: a key `~/.ssh/deploy_<first label of the host>` (ed25519, no passphrase, comment `deploy@<hostname>-<host>`), a `~/.ssh/known_hosts` entry (GitHub keys from `https://api.github.com/meta`, trusted via TLS; other hosts via `ssh-keyscan` with the fingerprints printed and a warning to compare them with the provider's documentation), a `Host <host>` block in `~/.ssh/config` with `IdentityFile` and `IdentitiesOnly yes`. The public key is printed — add it as a deploy key.

---

## wg-network — installing wg-network

Dependencies: preflight, base.

| Option | Type | Default | Purpose |
|---|---|---|---|
| `WG_REPO` | string | — | `owner/repo`; empty means the repository ubuntu-bootstrap was installed from (adv) |
| `WG_REF` | string | — | branch/tag/commit; empty means the same ref (adv) |

Downloads `ubuntu/wg/install.sh` of the given repository and ref over TLS, checks it with `bash -n` and runs it with `--repo` and `--ref`. The wg-network installer verifies and installs the tool atomically into `/opt/wg-network`. Configuring the WireGuard network is a separate layer: `sudo wg-network help` (`init-hub`, `init-peer`). The sysctl module keeps `ip_forward` enabled when WireGuard is installed; the firewall module does not touch WireGuard UDP ports — `wg-network` opens them itself.
