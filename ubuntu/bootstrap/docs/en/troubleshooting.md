# Troubleshooting

Start with these whenever something looks wrong:

```bash
sudo ubuntu-bootstrap doctor          # environment, integrity, stuck runs, pending confirmations
sudo ubuntu-bootstrap status          # which modules are applied, what is out of date
sudo ubuntu-bootstrap history         # runs; history <RUN_ID> shows exactly what a run changed
sudo less /var/log/ubuntu-bootstrap/<RUN_ID>.log
journalctl -t ubuntu-bootstrap
```

The tool's own messages are in Russian; this page explains the situations behind them.

## Lost SSH access after apply

If the change was waiting for confirmation (port change, enabling UFW), do nothing: after `SSH_CONFIRM_TIMEOUT` / `FW_CONFIRM_TIMEOUT` seconds (180 by default) it rolls back by itself and the previous access returns. If the server rebooted inside that window, `ubuntu-bootstrap-recover.service` performs the rollback at boot.

If access is still missing after the timeout, use the provider's console (VNC/serial) and run:

```bash
sudo ubuntu-bootstrap rollback --pending      # if something is still waiting for confirmation
sudo ubuntu-bootstrap history                 # find the run
sudo ubuntu-bootstrap rollback --last         # or rollback <RUN_ID> [--module ssh]
```

A rollback restores files from `/var/backups/ubuntu-bootstrap/<RUN_ID>/` and runs the undo commands (sshd restart, UFW rule removal). If the tool itself is unavailable, copy the files from the backup by hand: paths inside the backup directory mirror the absolute system paths.

Common causes the on-server self-check cannot see: a provider security group / firewall does not pass the new port; the client connects with the wrong key or a user not listed in `AllowUsers`. In such environments use `SSH_CONFIRM=wait` and confirm access from a new session with `confirm`.

## Exit code 3: stopped by a guard

The message names the exact reason. Typical ones (Russian message → meaning):

| Message | What to do |
|---|---|
| ни у одного разрешённого пользователя нет `authorized_keys` (no allowed user has authorized_keys) | set `ADMIN_SSH_KEYS` / `ADMIN_SSH_KEYS_GITHUB`, or let root's key be copied (`ADMIN_COPY_ROOT_KEYS`), or temporarily `SSH_PASSWORD_AUTH=yes` |
| `PermitRootLogin no`: нет пользователя с ключом и работающим sudo (no user with a key and working sudo) | set `ADMIN_SUDO_MODE=nopasswd` or a password (`ADMIN_PASSWORD_HASH` / `passwd`), or `SSH_PERMIT_ROOT=prohibit-password` |
| текущий пользователь не входит в `AllowUsers` (current user not in AllowUsers) | add the user to `SSH_ALLOW_USERS` or log in as the intended user |
| порт уже занят другим сервисом (port already in use) | pick another `SSH_PORT` |
| `FW_SSH_FROM` не включает IP текущей сессии (does not include the current session IP) | add your address to the list |
| DNS не готов (certbot: DNS not ready) | fix the A records, or `CERTBOT_DNS_CHECK=no` when the check is wrong (behind NAT, for example) |
| установлены конфликтующие пакеты (docker: conflicting packages installed) | `DOCKER_REMOVE_CONFLICTS=yes` |
| `SSH_CONFIRM=none` / `FW_CONFIRM=none` | a deliberately dangerous mode: `--force` |
| ОС не поддерживается (OS not supported) | `--force` lifts the version check; behaviour on other versions is untested |

`--force` lifts **every** guard at once; confirmations and the rollback timer remain.

## Exit code 4: changes rolled back

The confirmation timer expired, the self-check failed or "no" was answered. The server is in its previous state. See the causes above; after fixing them simply run `apply` again.

## Exit code 5: busy

- "ubuntu-bootstrap уже выполняется" (already running): another instance holds the lock; wait for it or check `ps aux | grep ubuntu-bootstrap`. The lock is released automatically even after SIGKILL (flock is released by the kernel).
- "модуль … ждёт подтверждения" (a module is waiting for confirmation): run `sudo ubuntu-bootstrap confirm` (from a new session) or `rollback --pending` first.
- "apt/dpkg занят" (apt/dpkg busy): right after boot `unattended-upgrades` may run for several minutes; the tool waits up to 5 minutes (preflight: 2 minutes). Check `ps aux | grep -E 'apt|dpkg|unattended'`.

## Exit code 1: module error

The module's changes have already been rolled back. The cause is in the output (the last lines of the failed command) and in the run log. Common cases:

- `apt-get` cannot find a package or has no network: check `BASE_EXTRA_PACKAGES`, `doctor` (HTTPS to `archive.ubuntu.com`).
- "не удалось скачать ключ" (could not download the key; docker/nginx): no access to `download.docker.com` / `nginx.org`.
- "отпечаток ключа не совпал" (fingerprint mismatch): the repository key changed or the traffic is being tampered with; do not continue until you understand why.
- `sshd -t: конфиг невалиден` (invalid config): a conflict with another file in `sshd_config.d`; see the `sshd -t` output.
- `visudo забраковал файл sudoers` (visudo rejected the file): a user name with disallowed characters.
- `jail sshd не поднялся` (the jail did not come up): `journalctl -u fail2ban`; usually `python3-systemd` is missing or another jail in `jail.d` is broken.

After fixing the cause run `apply` again: previously applied modules are skipped, the failed one is re-executed.

## A run is marked `running` or `interrupted`

`running` after a crash (SIGKILL, power loss) means the process could not record its status. Make sure the process is gone (`ps aux | grep ubuntu-bootstrap`), then `rollback <RUN_ID>` if needed. `interrupted` means the process received SIGTERM/SIGINT and finished between steps; its changes are not rolled back automatically — `rollback <RUN_ID>` does that.

## fail2ban banned my IP

```bash
sudo fail2ban-client status sshd
sudo fail2ban-client set sshd unbanip <IP>
```

To prevent it: `F2B_IGNOREIP=<your IP or network>`; the current session's IP is added automatically with `F2B_IGNORE_CURRENT=yes`.

## A Docker container is unreachable from outside

That is the DOCKER-USER protection (`FW_DOCKER_PROTECT`). The intended setup publishes container ports on `127.0.0.1` and proxies them through nginx. If a container must be reachable directly:

```bash
sudo ubuntu-bootstrap config set FW_DOCKER_ALLOW_PORTS=8080/tcp
sudo ubuntu-bootstrap apply --only firewall
```

## Changing a setting after apply

```bash
sudo ubuntu-bootstrap config set SSH_PORT=2222
sudo ubuntu-bootstrap plan
sudo ubuntu-bootstrap apply
```

Only modules whose options changed are re-applied. `apply --reapply` forces every selected module (idempotently).

## Disabling a module and removing its settings

Removing a module from the set (`MODULES_SKIP=…`) does not delete its files: the tool performs no destructive action without an explicit command. To return the system to the state before the module, run `rollback <RUN_ID> --module <name>` for the run that applied it (see `history`). The tool's files are easy to recognise: `ubuntu-bootstrap` in the file name or a `# BEGIN ubuntu-bootstrap …` block inside a foreign file.

## sshd does not listen on the new port after apply

On Ubuntu 22.10+ sshd is socket-activated; the tool restarts `ssh.socket` itself. If the port still did not change: `systemctl status ssh.socket`, `ss -ltn`, `sshd -T | grep ^port`. Check for a file in `/etc/ssh/sshd_config.d/` with a prefix lower than `00-`, or a `ListenAddress` in the main config.

## certbot did not issue a certificate

Typical causes: the domain's DNS does not point at the server; port 80 is closed by the provider; nginx does not listen on 80; Let's Encrypt rate limits (5 failures per hour per domain set) — use `CERTBOT_STAGING=yes` for debugging. Details in `/var/log/letsencrypt/letsencrypt.log`.

## The wizard refuses to start without a terminal

`wizard` is interactive by definition. For automation use `apply --profile NAME --set KEY=VALUE ... --yes` or a configuration file (`config init`, then `apply`).

## Inside a container / LXC

swap, the NTP daemon and snap (certbot comes from apt) are skipped; sysctl is applied only for writable keys; UFW needs `NET_ADMIN`. `status` shows such modules as `n/a`.

## Where things are

| What | Path |
|---|---|
| Run log | `/var/log/ubuntu-bootstrap/<RUN_ID>.log` |
| Events | `journalctl -t ubuntu-bootstrap` |
| Change journal | `/var/lib/ubuntu-bootstrap/runs/<RUN_ID>/journal` (`history <RUN_ID>` renders it) |
| Backups | `/var/backups/ubuntu-bootstrap/<RUN_ID>/<absolute path>` |
| Module state | `/var/lib/ubuntu-bootstrap/modules/<module>.env` |
| Pending confirmation | `/var/lib/ubuntu-bootstrap/pending.env` |
| Configuration | `/etc/ubuntu-bootstrap/bootstrap.conf` |
| Files the tool writes | `/etc/ssh/sshd_config.d/00-ubuntu-bootstrap.conf`, `/etc/fail2ban/jail.d/ubuntu-bootstrap.local`, `/etc/sysctl.d/9[0-2]-ubuntu-bootstrap-*.conf`, `/etc/security/limits.d/90-ubuntu-bootstrap.conf`, `/etc/systemd/system.conf.d/90-ubuntu-bootstrap.conf`, `/etc/systemd/journald.conf.d/90-ubuntu-bootstrap.conf`, `/etc/apt/apt.conf.d/52ubuntu-bootstrap-unattended`, `/etc/apt/apt.conf.d/20auto-upgrades`, `/etc/sudoers.d/90-ubuntu-bootstrap-<user>`, `/etc/nginx/conf.d/00-ubuntu-bootstrap.conf`, `/etc/nginx/snippets/security-headers.conf`, `/etc/docker/daemon.json` (merged), `/etc/apt/sources.list.d/{docker,nginx}.sources`, `/etc/apt/keyrings/{docker,nginx}.asc`, blocks in `/etc/fstab`, `/etc/hosts`, `/etc/ufw/after.rules` |
