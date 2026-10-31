# Getting started

This guide takes you from an empty server to a working network: one hub, a few servers connected to it, and a phone or laptop. Every step explains what happens on the machine, so nothing comes as a surprise.

- [Requirements](#requirements)
- [Install](#install)
- [Create the hub](#create-the-hub)
- [Connect a server](#connect-a-server)
- [Connect a laptop or phone](#connect-a-laptop-or-phone)
- [Check that everything works](#check-that-everything-works)
- [What to read next](#what-to-read-next)

## Requirements

| What | Details |
|---|---|
| OS | Ubuntu 20.04+ or Debian 11+ (tested: Ubuntu 22.04, 24.04, 26.04) |
| Shell | bash 4.4 or newer |
| Kernel | the `wireguard` module (built into every supported Ubuntu kernel) |
| Init | systemd is recommended; without it interfaces are managed with `wg-quick` directly and the reboot protection is not available |
| Packages | `wireguard-tools` (installed automatically through `apt-get` when missing), `iproute2`, `iptables` (only for routing and NAT on the hub), `curl` or `wget` for installation |
| Rights | root (`sudo`) for every command except `help` and `version` |
| Network | the hub needs one UDP port reachable from the peers (51820 by default) |

The hub is the only node that must be reachable from the outside. Peers may sit behind NAT: they connect to the hub and keep the connection alive with a keepalive.

## Install

Run on every server that will take part in the network:

```bash
curl -fsSL https://raw.githubusercontent.com/Ange1oc/devops_template/main/ubuntu/wg/install.sh | sudo bash
```

For a reproducible installation pin a tag or a commit:

```bash
curl -fsSL https://raw.githubusercontent.com/Ange1oc/devops_template/main/ubuntu/wg/install.sh | sudo bash -s -- --ref <commit-sha>
```

What the installer does:

1. Downloads the repository archive over HTTPS (TLS 1.2+) and takes only `ubuntu/wg` from it.
2. Refuses a tree that contains symlinks.
3. Copies it to a staging directory owned by root, checks every script with `bash -n` and runs the new version once.
4. Only then replaces `/opt/wg-network` atomically, keeping the previous version in `/opt/wg-network.old`.
5. Links `/usr/local/bin/wg-network`, installs bash completion and the `wg-network-reresolve.timer` systemd timer.

The installer never touches the network: no interface is created or restarted.

Check the installation:

```bash
wg-network version
sudo wg-network help
```

> Tests are not installed. The installation directory must be owned by root and not writable by other users: commands that run later as root (the rollback timer, the boot-time check) are executed from it. A copy in a home directory works, but wg-network warns about it and does not install the boot protection.

## Create the hub

Pick the server with a public address. `--endpoint` is the address peers will use to reach it: a public IP or, better, a DNS name.

```bash
sudo wg-network init hub --endpoint vpn.example.com
```

Defaults: tunnel network `10.50.0.0/24` with the hub at `10.50.0.1`, UDP port `51820`. Change them with `--address 10.60.0.1/24` and `--port 51821`.

What you will see:

1. **Checks.** wg-network refuses to start if `/etc/wireguard/wg0.conf` already exists and was not created by it, if a `wg0` interface already exists, if the UDP port is busy, or if the network overlaps a route of the server (LAN, Docker, another VPN). This protects VPNs that already run on the machine.
2. **A plan.** The list of changes and the way they will be applied (`запуск wg0`: start of the interface).
3. **A question** whether to apply. Without a terminal (cron, CI) the answer is "no": the change is only prepared. Use `--yes` in automation.
4. **Confirmation.** Starting an interface can affect access to the server, so after the start you get `CONFIRM_TIMEOUT` seconds (120 by default) to confirm. In an interactive session type `yes`. If you do not confirm, the previous state is restored automatically, even when your SSH session has dropped.
5. **The firewall.** If UFW is active, the UDP port is opened in UFW. With firewalld you get the exact command to run yourself. A cloud security group must be opened by you.

Result: the interface `wg0` is up, enabled in systemd (`wg-quick@wg0`), and the config `/etc/wireguard/wg0.conf` is generated from the state in `/etc/wireguard/wg-network/wg0/`.

```bash
sudo wg-network status
```

By default peers see only the hub (isolation). To let them reach each other, see [Routing between peers](scenarios.md#routing-between-peers).

## Connect a server

There are two ways: one command from the hub over SSH, or by hand with a token.

### One command from the hub (deploy)

Requirements: from the hub you can log in to the new server with an SSH key (non-interactively) as root or as a user with password-less `sudo`.

```bash
sudo wg-network deploy worker1 root@203.0.113.21 --install
```

Steps, each one printed as it runs:

1. **invite**: a tunnel address is reserved for `worker1` and an invitation token is created.
2. **install** (`--install`): wg-network is installed on the remote server with the same installer.
3. **join**: the remote server joins the network. The token is sent through the SSH session's stdin, so it never appears in a command line or a shell history.
4. **peer add**: the server's public key is added on the hub. The change is hot: other tunnels are not interrupted.
5. **handshake**: wg-network waits up to 20 seconds (`--wait N`) for the first handshake and reports whether the connection really works. Exit code 6 means "applied, but no handshake yet".

If the installation or the join fails, the reservation is removed and the error says what happened. Guards on the remote side still work: for example, a full tunnel that would cut SSH access to that server is refused there.

### By hand with a token

On the hub:

```bash
sudo wg-network invite worker1
```

It reserves an address and prints two commands for the new server plus the token on its own line. On the new server:

```bash
curl -fsSL https://raw.githubusercontent.com/Ange1oc/devops_template/main/ubuntu/wg/install.sh | sudo bash
sudo wg-network join
```

`join` asks for the token with hidden input (you can also pipe it: `printf '%s\n' "$TOKEN" | sudo wg-network join -`, or use `--token-file FILE`). It creates the peer side, brings the interface up and prints the command to run on the hub:

```bash
sudo wg-network peer add worker1 --key 'Xy...='
```

Run it on the hub. The connection is established within about 5 seconds (the peer retries its handshake every `REKEY_TIMEOUT`).

> **The token is a secret.** It contains the preshared key of this peer. Do not post it in chats or tickets. Passing it as an argument (`join wgn1....`) works but prints a warning: arguments are visible to every user of the server through `ps`.

## Connect a laptop or phone

Devices that do not run wg-network get a ready client config. Keys are generated on the hub, and the private key is **not** stored there:

```bash
sudo wg-network peer add phone --generate --qr --dns 1.1.1.1
sudo wg-network peer add laptop --generate --output /root/laptop.conf
```

- `--qr` prints a QR code for the WireGuard mobile app (needs `qrencode`).
- `--output FILE` writes the config with mode 600 and refuses to follow an existing file or symlink.
- Without either, the config goes to stdout. Save it now: it cannot be shown again.

To send all of the device's traffic through the hub (an exit node) see [Exit node](scenarios.md#exit-node-internet-through-the-hub).

## Check that everything works

```bash
sudo wg-network status        # role, addresses, pending changes, peer table
sudo wg-network peer list     # NAME ADDRESS STATE ENDPOINT HANDSHAKE RX TX ROUTES
sudo wg-network doctor        # full self-check; exit code 0 ok, 1 warnings, 2 errors
```

Peer states: `online` (handshake within 3 minutes), `stale` (older), `no-handshake` (never), `down` (the interface is not running), `disabled`, `invited` (reserved, waiting for `peer add`).

From a peer, ping the hub: `ping 10.50.0.1`.

## What to read next

- [How it works](concepts.md): state, plans, the ways changes are applied, guards, confirmation and rollback.
- [Command reference](commands.md): every command and option, exit codes, JSON output, settings.
- [Scenarios](scenarios.md): routing between peers, site-to-site, exit node, IPv6, several networks, replacing a server.
- [Operations](operations.md): monitoring, troubleshooting, recovery, upgrades, performance, limitations.
