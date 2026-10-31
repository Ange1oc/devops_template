# wg-network

[Русская версия](README.ru.md)

**wg-network** builds and manages WireGuard networks on production Linux servers: a hub with a public address and any number of peers (servers, office gateways, laptops, phones). It covers the whole life of a network: installing with one command, connecting a server over SSH with one command, routing between peers, site-to-site links, an exit node, IPv6, backups and recovery.

Its main rule: **a running VPN and your SSH access matter more than any change.**

- Preparing a change and applying it are separate steps, and every change shows a plan first.
- Peer changes are applied hot: other tunnels are not interrupted.
- Changes that can cut connectivity run under an automatic rollback timer, like `netplan try`. The timer survives a dropped SSH session and a reboot.
- Changes that would cut an SSH session are blocked until you explicitly allow them.
- Every change starts with a snapshot; an interrupted command is rolled back, and any earlier state can be restored.
- `--dry-run` really changes nothing: this is verified by tests for every command.

```bash
curl -fsSL https://raw.githubusercontent.com/Ange1oc/devops_template/main/ubuntu/wg/install.sh | sudo bash

sudo wg-network init hub --endpoint vpn.example.com                 # on the hub
sudo wg-network deploy worker1 root@203.0.113.21 --install          # connect a server, from the hub
sudo wg-network peer add phone --generate --qr                      # a phone or laptop
sudo wg-network status
```

## Documentation

| Document | What is inside |
|---|---|
| [Getting started](docs/en/getting-started.md) | requirements, installation, the first hub, connecting servers and devices, checking the result |
| [How it works](docs/en/concepts.md) | roles, desired state vs. live config, plans and apply classes, approval, confirmation and rollback, guards, snapshots, dry-run, secrets, validation, files |
| [Command reference](docs/en/commands.md) | every command and option, exit codes, settings, the installer, JSON output |
| [Scenarios](docs/en/scenarios.md) | routing between peers, site-to-site, exit node, IPv6, several networks, moving or replacing the hub, key rotation, automation, migration |
| [Operations](docs/en/operations.md) | monitoring, audit log, troubleshooting, recovery, upgrades, performance, security notes, limitations |
| [Development](docs/en/development.md) | code layout, conventions, adding a command, tests, coverage, CI |

## At a glance

| | |
|---|---|
| Platforms | Ubuntu 20.04+, Debian 11+ (tested on Ubuntu 22.04, 24.04, 26.04), bash 4.4+, kernel WireGuard module, systemd recommended |
| Topology | hub and spoke; peers isolated by default; optional forwarding, NAT, site-to-site, full tunnel, dual-stack IPv6 |
| Installed to | `/opt/wg-network`, command `/usr/local/bin/wg-network` |
| Generated config | `/etc/wireguard/<iface>.conf`, standard `wg-quick`, works without wg-network |
| State | `/etc/wireguard/wg-network/<iface>/` |
| Dependencies | `wireguard-tools`, `iproute2`; `iptables` for routing/NAT; nothing else |
| Interface language | messages in Russian; commands, options, JSON and exit codes are language-neutral |

## Testing status

The project is tested on several levels without mocking the network: unit tests, end-to-end tests with the kernel WireGuard module in network namespaces (17 nodes, real handshakes, NAT, site-to-site, failures, rollbacks), integration tests with a real systemd and OpenSSH in containers, and the same suites on several Ubuntu releases. Coverage is measured from execution traces. See [Development](docs/en/development.md#tests).

Not verified: virtual machines and hardware, Debian/RHEL, sudden power loss, a successful download from GitHub inside the tests. See [Limitations](docs/en/operations.md#limitations).
