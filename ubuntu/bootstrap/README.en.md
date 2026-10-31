# ubuntu-bootstrap

[Русская версия](README.md)

Modular, one-command production setup for a fresh Ubuntu server: admin user and SSH keys, SSH hardening, UFW, fail2ban, automatic security updates, sysctl and limits, swap, journald, Docker CE, nginx, certbot, Git deploy keys. Supports Ubuntu 22.04, 24.04 and 26.04 LTS on amd64 and arm64.

The core principle: **no action may lock you out of the server or break what is already configured.** Guards verify that an administrator with a key and working sudo remains after every change. Risky steps (SSH, firewall) are armed with a rollback timer and must be confirmed from a new session. Every module is idempotent; its changes are journaled, backed up and rolled back on failure.

## Quick start

Install and start the interactive wizard:

```bash
curl -fsSL https://raw.githubusercontent.com/Ange1oc/devops_template/main/ubuntu/bootstrap/install.sh | sudo bash -s -- --run
```

Non-interactive, one command (cloud-init, Ansible, CI):

```bash
sudo ubuntu-bootstrap apply --profile web \
    --set ADMIN_USER=deploy \
    --set 'ADMIN_SSH_KEYS=ssh-ed25519 AAAA... admin@laptop' \
    --set ADMIN_SUDO_MODE=nopasswd \
    --set CERTBOT_DOMAINS=example.com --set CERTBOT_EMAIL=ops@example.com \
    --yes
```

With a configuration file:

```bash
sudo ubuntu-bootstrap config init --profile docker
sudo ubuntu-bootstrap config set ADMIN_USER=deploy ADMIN_SSH_KEYS_GITHUB=mylogin DOCKER_USERS=deploy
sudo ubuntu-bootstrap plan      # show what would change without changing anything
sudo ubuntu-bootstrap apply
```

After an SSH port change or enabling the firewall the tool waits for confirmation: log in through a **new** session and run `sudo ubuntu-bootstrap confirm`. Without confirmation the change rolls back by itself after 180 seconds.

## What gets configured

| Profile | Modules |
|---|---|
| `minimal` | preflight, base, time, users, ssh, firewall, fail2ban, updates, journald |
| `web` | minimal + sysctl, limits, swap, nginx (nginx.org stable), certbot; ports 80/443 open |
| `docker` | minimal + sysctl, limits, swap, docker; containers protected from bypassing UFW |
| `full` | web + docker + git + wg-network |

Any module can be enabled or disabled on its own (`--only`, `--skip`, `MODULES=` in the config); dependencies are pulled in automatically. The full option list: `ubuntu-bootstrap modules --options`.

## Documentation

| Document | Contents |
|---|---|
| [Installation](docs/en/install.md) | installation methods, integrity verification, update, rollback, removal |
| [Usage](docs/en/usage.md) | commands, global options, exit codes, configuration, profiles, automation scenarios |
| [Modules](docs/en/modules.md) | every module in detail: what it does, all options, files, guards, checks |
| [Safety](docs/en/safety.md) | guards, confirmation and rollback timer, transactions, what is never touched |
| [Architecture](docs/en/architecture.md) | code layout, execution flow, on-disk state, design decisions and their sources |
| [Extending](docs/en/extending.md) | custom modules and profiles, helper API, module contract |
| [Testing](docs/en/testing.md) | lint, unit, e2e in containers, coverage, CI |
| [Troubleshooting](docs/en/troubleshooting.md) | lost access, common errors, where the logs are |
| [Audit](docs/en/audit.md) | issues found and fixed, remaining risks |

Messages printed by the tool itself are in Russian; this documentation explains every message and exit code.

## Layout on disk

```
/opt/ubuntu-bootstrap/                 the program; .old keeps the previous version for rollback
/usr/local/bin/ubuntu-bootstrap        symlink to the executable
/etc/ubuntu-bootstrap/bootstrap.conf   configuration (KEY=VALUE, mode 600)
/etc/ubuntu-bootstrap/modules.d/       custom modules
/etc/ubuntu-bootstrap/profiles.d/      custom profiles
/var/lib/ubuntu-bootstrap/             module state, run journals, pending.env
/var/backups/ubuntu-bootstrap/<run>/   copies of changed files
/var/log/ubuntu-bootstrap/<run>.log    full log of every run
```

## Tests

```bash
ubuntu/bootstrap/tests/run.sh lint      # shellcheck
ubuntu/bootstrap/tests/run.sh unit      # ~200 checks, no root, no network
ubuntu/bootstrap/tests/run.sh e2e       # Ubuntu containers with systemd and real sshd/ufw/fail2ban
ubuntu/bootstrap/tests/run.sh coverage  # the same under kcov
```

The host is never modified by the tests: everything runs in containers.
