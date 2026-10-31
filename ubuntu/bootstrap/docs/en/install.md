# Installation

## Requirements

| What | Requirement |
|---|---|
| OS | Ubuntu 22.04, 24.04 or 26.04 LTS (other versions are stopped by a guard; `--force` lifts only this check) |
| Architecture | amd64 or arm64 (others produce a warning) |
| Privileges | root (`sudo`); only `help`, `version`, `modules`, `profiles` and `doctor` work without root |
| Tools | bash 4.4+, `curl` or `wget`, `systemd` (without it services and rollback timers are unavailable) |
| Network | HTTPS to `github.com` and `archive.ubuntu.com`; for Docker and nginx.org also their repositories |

Containers (Docker, LXC) are supported partially: swap, kernel sysctl and the NTP daemon belong to the host and are skipped; snap is unavailable.

## Installation methods

### One command

```bash
curl -fsSL https://raw.githubusercontent.com/Ange1oc/devops_template/main/ubuntu/bootstrap/install.sh | sudo bash
```

The same with `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/Ange1oc/devops_template/main/ubuntu/bootstrap/install.sh | sudo bash
```

Install and start the wizard right away:

```bash
curl -fsSL https://raw.githubusercontent.com/Ange1oc/devops_template/main/ubuntu/bootstrap/install.sh | sudo bash -s -- --run
```

Arguments after `-s --` are passed to the installer.

### With integrity verification

| Variant | Command | What is verified |
|---|---|---|
| Release | `... \| sudo bash -s -- --ref ubuntu-bootstrap-v1.0.0` | the tarball's SHA256 is compared with the release's `SHA256SUMS`. With `UBB_SIGNING_KEY_FPR` set or `--require-signature`, the GPG signature `SHA256SUMS.asc` is verified too |
| Commit | `... \| sudo bash -s -- --ref <sha>` | the content is pinned by the commit hash and cannot be replaced without changing the reference |
| Any ref | `... \| sudo bash -s -- --ref main --sha256 <hash>` | the SHA256 of the downloaded archive must match |
| Local | `sudo ./ubuntu/bootstrap/install.sh --local` | nothing is downloaded; installs from the current clone |

Verifying a release signature:

```bash
export UBB_SIGNING_KEY_FPR=<fingerprint of the maintainer's key>
curl -fsSL .../install.sh | sudo -E bash -s -- --ref ubuntu-bootstrap-v1.0.0 --require-signature
```

The key is fetched from `keys.openpgp.org` into a temporary GnuPG home; the signature must be made by exactly that key (`VALIDSIG`). Without a fingerprint the signature is not checked and trust rests on TLS and `SHA256SUMS`, as with `get.docker.com`.

### Private repository or fork

```bash
sudo GITHUB_TOKEN=ghp_... bash install.sh --repo owner/repo --ref main
```

With a token the archive is downloaded through the GitHub API (`api.github.com/repos/<repo>/tarball/<ref>`); without one through `github.com/<repo>/archive/<ref>.tar.gz`, which is not subject to the API rate limit. `UBB_REPO` and `UBB_REF` set the defaults for `--repo` and `--ref`; they are also recorded in the installation metadata and used by `self-update`.

## What the installer does

1. Checks that it runs as root with bash 4.4 or newer; validates `--repo` and `--ref` (no `..`, safe characters only).
2. Downloads the archive over HTTPS with TLS 1.2+ only, with retries; redirects to `http://` are refused (`curl --proto '=https'`, `wget --https-only`).
3. For a release tag verifies `SHA256SUMS` and, when a fingerprint is set, the signature. With `--sha256` compares the archive hash.
4. Extracts only the `ubuntu/bootstrap` directory with `--no-same-owner --no-same-permissions`; checks that it contains `ubuntu-bootstrap`, `lib/`, `modules/`, `commands/`.
5. Refuses to install a tree containing symbolic links (except in `tests/`, which is not installed).
6. Copies to `/opt/ubuntu-bootstrap.new`, sets `root:root`, directories 755, files 644, executables 755.
7. Runs `bash -n` on every `.sh`, `.bash` file and the entry point; runs `ubuntu-bootstrap version` from the staging directory.
8. Writes `.install` (REPO, REF, COMMIT, INSTALLED_AT).
9. Swaps the directory atomically: the previous version becomes `/opt/ubuntu-bootstrap.old`.
10. Creates the symlink `/usr/local/bin/ubuntu-bootstrap`, installs bash completion, installs and enables `ubuntu-bootstrap-recover.service` (rollback of unconfirmed changes after a reboot).

The whole installer body lives inside the `main` function that is called on the last line: a download truncated half-way through `curl | bash` executes nothing.

To read the installer before running it:

```bash
curl -fsSL https://raw.githubusercontent.com/Ange1oc/devops_template/main/ubuntu/bootstrap/install.sh -o install.sh
less install.sh
sudo bash install.sh
```

## What appears on disk

| Path | Purpose |
|---|---|
| `/opt/ubuntu-bootstrap/` | the program (entry point, `lib/`, `commands/`, `modules/`, `profiles/`, `completion/`, `systemd/`, `install.sh`, `VERSION`, `.install`) |
| `/opt/ubuntu-bootstrap.old/` | the previous version, present after an update |
| `/usr/local/bin/ubuntu-bootstrap` | symlink to the entry point |
| `/etc/bash_completion.d/ubuntu-bootstrap` | completion of commands, modules, profiles and options |
| `/etc/systemd/system/ubuntu-bootstrap-recover.service` | rollback at boot when `pending.env` is left behind |

State directories (`/etc/ubuntu-bootstrap`, `/var/lib/ubuntu-bootstrap`, `/var/backups/ubuntu-bootstrap`, `/var/log/ubuntu-bootstrap`) are created with mode 700 on the first run of a command that changes something.

## Checking the installation

```bash
ubuntu-bootstrap version      # version, source and installation time
ubuntu-bootstrap doctor       # environment, installation integrity, run state
```

`doctor` exits 0 when everything is fine, 1 with warnings, 2 with errors. It verifies that `/opt/ubuntu-bootstrap` is owned by root and not writable by others, because the rollback timer and the recover service execute code from there as root.

## Updating

```bash
sudo ubuntu-bootstrap self-update --check   # compare the installed version with VERSION in the repository
sudo ubuntu-bootstrap self-update           # update from the same repo/ref as the installation
sudo ubuntu-bootstrap self-update --ref ubuntu-bootstrap-v1.1.0
```

`self-update` runs `install.sh` with the recorded `REPO` and `REF`. Only the program is updated: configuration, module state, journals and backups are untouched. If the tool was not installed through `install.sh` (no `.install` file), `self-update` refuses and suggests a regular installation.

## Rolling an update back

```bash
sudo /opt/ubuntu-bootstrap/install.sh --rollback
```

The current version and `.old` swap places; links and the recover service are reinstalled. Running `--rollback` again swaps them back.

## Removal

```bash
sudo /opt/ubuntu-bootstrap/install.sh --uninstall           # program, link, completion, recover service
sudo /opt/ubuntu-bootstrap/install.sh --uninstall --purge   # plus configuration, state, logs and backups
```

Removing the tool does not affect the configured services: sshd, UFW, fail2ban, unattended-upgrades, Docker and nginx keep running with their configs. Without `--purge`, `/etc/ubuntu-bootstrap`, `/var/lib/ubuntu-bootstrap`, `/var/backups/ubuntu-bootstrap` and `/var/log/ubuntu-bootstrap` stay, so a reinstall sees the previous configuration and history.

If a change is still waiting for confirmation, confirm or roll it back first (`confirm` / `rollback --pending`): after removal the rollback timer can no longer fire.

## Installer parameters

| Parameter | Purpose |
|---|---|
| `--ref REF` | branch, tag or commit (default `main` or `UBB_REF`) |
| `--repo OWNER/REPO` | GitHub repository (default `Ange1oc/devops_template` or `UBB_REPO`) |
| `--sha256 HASH` | expected SHA256 of the downloaded archive |
| `--require-signature` | require the `SHA256SUMS.asc` signature (needs `UBB_SIGNING_KEY_FPR`) |
| `--run` | start `ubuntu-bootstrap wizard` after installation |
| `--local [DIR]` | install from a local copy (default: the directory containing `install.sh`) |
| `--rollback` | restore the previous version |
| `--uninstall [--purge]` | remove the program (with `--purge` also all data) |
| `-h`, `--help` | help |

Environment variables: `UBB_REPO`, `UBB_REF`, `UBB_SIGNING_KEY_FPR`, `GITHUB_TOKEN`.
