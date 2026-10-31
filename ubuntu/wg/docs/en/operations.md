# Operations

Day-to-day running of wg-network: monitoring, troubleshooting, recovery, upgrades and the limits you should know about.

- [Monitoring](#monitoring)
- [Audit log](#audit-log)
- [Troubleshooting](#troubleshooting)
- [Recovery procedures](#recovery-procedures)
- [Upgrading and uninstalling](#upgrading-and-uninstalling)
- [Performance](#performance)
- [Security notes](#security-notes)
- [Limitations](#limitations)

## Monitoring

| What | How | Signal |
|---|---|---|
| Overall health | `wg-network doctor` | exit 0 ok, 1 warnings, 2 errors |
| Unapplied changes (drift between state and config) | `wg-network plan` | exit 10 |
| Peers | `wg-network peer list --json` | `state` per peer, `latest_handshake`, traffic |
| Node | `wg-network status --json` | `up`, `state_valid`, `pending_confirmation`, `manual_edits`, `unapplied_changes` |
| Changes | `journalctl -t wg-network` | who changed what, with the snapshot id |

A minimal check for a monitoring agent (Zabbix, Nagios, a cron job):

```bash
sudo wg-network doctor --quiet >/dev/null; echo $?          # 0 / 1 / 2
sudo wg-network peer list --json | jq -r '.[] | select(.state != "online" and .state != "disabled") | .name'
```

Peers without traffic do not handshake. A peer that is idle and has no keepalive shows `stale` while being perfectly fine; peers created by wg-network send a keepalive every 25 s, so for them `stale` means unreachable.

## Audit log

Every change is logged to syslog/journald with the tag `wg-network`:

```
iface=wg0 user=alice peer-add name=worker1 address=10.50.0.2 key=... routes=none
iface=wg0 user=alice apply class=hot snapshot=20260131-101500-peer-add result=1
iface=wg0 user=root rollback mode=auto class=restart txid=...
```

`user` is the sudo user when available. Private keys and tokens are never logged.

## Troubleshooting

Start with `sudo wg-network doctor`: it checks most of the causes below and says what to run.

| Symptom | Likely cause | What to do |
|---|---|---|
| A peer is `no-handshake` | wrong key; the hub's UDP port closed (UFW, cloud security group); wrong endpoint; the peer is not running | compare `wg-network public-key` on the peer with `peer show NAME` on the hub; check the port from outside; `doctor` on both sides |
| A peer was online, now `stale` | the peer is down or its network changed; the hub's IP changed | check the peer; with a DNS endpoint the re-resolution timer recovers within ~2–3 minutes; otherwise `peer set hub --endpoint` on the peer |
| Peers cannot reach each other | the hub does not forward, or the peers only have the hub route | `set --forward on` on the hub; `peer set hub --routes 10.50.0.0/24` on old peers |
| An exit-node client has no internet | NAT not enabled; forwarding on the uplink is off; DNS on the client | `set --nat eth0`; `doctor` shows the forwarding and MASQUERADE state; set `--dns` for generated clients |
| TCP hangs through the tunnel, ping works | MTU / PMTUD problems | MSS clamping is on for routed traffic; try `set --mtu 1380` (PPPoE: 1412) |
| `ERROR: ... изменён вручную` (edited by hand), exit 3 | someone edited `/etc/wireguard/<iface>.conf` | `plan --diff` shows the edit; move the edit into wg-network commands, or `--force` to overwrite (the manual version is backed up) |
| Exit 5, "занят" (busy) | another wg-network is running, or a change waits for confirmation | wait, or `confirm` / `rollback` the pending change |
| Exit 3, "заблокирована предохранителем" (blocked by a guard) | the change would cut an SSH session | read the warning; connect differently, or `--force` if you are sure (the timer still protects you) |
| The change was rolled back by itself | nobody confirmed within `CONFIRM_TIMEOUT` | the state is back to the previous snapshot; `history` shows the `rejected` snapshot to retry with `rollback <id>` |
| `состояние ... повреждено` (state damaged) | a state file was edited or truncated | the message lists the problems; fix the file or `rollback` to a snapshot |
| `doctor`: "peer в ядре отличаются от конфига" | someone used `wg set` directly | `wg-network apply` brings the kernel back (hot) |
| `doctor`: no `wg-network.conf` drop-in | the program runs from a directory writable by non-root users, or `apply` has not run since installation | install with `install.sh`; the drop-in is added on the next apply |
| `doctor`: time not synchronized | NTP is off | enable NTP: a clock that jumps backwards makes peers reject handshakes until it catches up |

Useful low-level commands:

```bash
sudo wg show                                  # kernel view: peers, endpoints, handshakes, transfer
sudo wg-network show                          # live config, secrets masked
sudo wg-network show --candidate              # what the next apply would write
journalctl -u wg-quick@wg0 -n 50              # interface start/stop errors
ip route show table all | grep wg0            # routes installed by wg-quick
sudo iptables -S | grep wg-network            # firewall rules added by wg-network
```

## Recovery procedures

**A change locked me out.** Do nothing: after `CONFIRM_TIMEOUT` seconds (120 by default) the previous config comes back by itself, even if your session is gone. If the server reboots before that, the previous config is brought up at boot.

**I need to undo the last change.** `sudo wg-network rollback`. For an older state: `sudo wg-network history`, then `sudo wg-network rollback <id>`.

**wg-network was killed in the middle of a change.** The next run of any changing command finds the unfinished transaction and restores the state from its snapshot. `doctor` reports it before that.

**The state directory is damaged.** Every command refuses to render it and lists the problems. Fix the listed files, or restore a snapshot: `sudo wg-network rollback <id>`. Snapshots are plain tar files in `/etc/wireguard/wg-network/<iface>/snapshots/`.

**The server is lost.** Restore the backup on a new server (`wg-network restore`), see [Replacing a failed hub](scenarios.md#replacing-a-failed-hub). Without a backup, create a new hub and re-invite every peer.

**I want to stop managing an interface with wg-network but keep the tunnel.** Uninstall the program (`install.sh --uninstall`): the generated config is self-contained and `wg-quick@<iface>` keeps working. The state stays in `/etc/wireguard/wg-network` in case you reinstall.

**I want to remove an interface completely.** `sudo wg-network -i wg0 destroy`. An archive of the state and the config is kept in `/var/backups/wg-network/`.

## Upgrading and uninstalling

| Action | Command |
|---|---|
| Update to the latest version of the installed ref | `sudo wg-network self-update` |
| Update to a specific version | `sudo wg-network self-update --ref <tag-or-commit>` |
| Return to the previous version | `sudo /opt/wg-network/install.sh --rollback` |
| Remove the program | `sudo /opt/wg-network/install.sh --uninstall` |
| Install from a local checkout | `sudo ./ubuntu/wg/install.sh --local` |

Updating only replaces the program in `/opt/wg-network`. Interfaces are not restarted and keys and configs are not touched. If the new version renders a different header in the config, the next change rewrites the file without restarting anything (`rewrite` class). State from older versions is migrated automatically.

Uninstalling removes the program, the timer, the drop-ins and the completion. Tunnels keep running; the state stays in `/etc/wireguard/wg-network`; nothing in `/etc/wireguard/*.conf` is removed. Without the program there is no boot-time rollback for changes that were never confirmed, so confirm or roll back pending changes before uninstalling.

## Performance

What wg-network does for you:

- **Kernel module only.** `doctor` warns when `wireguard-go` is running: the userspace implementation is several times slower.
- **Fast recovery after a hub restart.** Peers without a configured endpoint would be unknown to the hub until they send something, and they notice a lost session only after `KEEPALIVE_TIMEOUT + REKEY_TIMEOUT` (~15 s). wg-network restores the last known endpoints and starts the handshake itself. Measured on the test setup: traffic resumed after about 5 ms instead of 16.4 s.
- **A stable port for hot changes.** `wg syncconf` with a config without `ListenPort` (every peer node) picks a new random port, as does `systemctl reload wg-quick@`. The hub would then send to the old port until the next keepalive (up to 25 s). wg-network keeps the current port.
- **MSS clamping** for routed and NATed traffic: without it TCP stalls wherever PMTUD is broken.
- **Per-interface forwarding** (`net.ipv4.conf.<iface>.forwarding`) instead of the global `ip_forward`, because changing `ip_forward` resets other IPv4 settings (kernel `ip-sysctl` documentation).
- **MTU.** By default `wg-quick` uses the route MTU minus 80 (1420 for 1500). Use `--mtu` for PPPoE (1412) or nested tunnels. `doctor` warns about an MTU above 1420.
- **Keepalive only where needed.** 25 s from peers that may be behind NAT; none from the hub.
- **conntrack.** On an exit node `doctor` watches `nf_conntrack` usage.

What wg-network deliberately does **not** do: global system tuning (`net.core.rmem_max`, BBR, `netdev_budget`, RPS, CPU affinity). These settings affect every service on the host. For the kernel WireGuard module UDP socket buffers are not on the data path: packets are processed in softirq context before reaching a socket queue. If you tune, measure before and after (`iperf3` through the tunnel).

Scale: the tests run a hub with 250 peers. On the test machine applying all 250 took about 7 s, adding one more peer about 9 s and `status --json` about 10 s. The data path is the kernel and does not slow down; management commands are bash and grow linearly with the number of peers, so with many hundreds of peers expect each command to take tens of seconds.

## Security notes

- Keep the program where only root can write to it (`/opt/wg-network` from the installer). Commands that run later as root (the rollback timer, the boot-time check) execute it. A copy in a home directory triggers a warning and no boot drop-in is installed.
- The state directory contains the private key; it is 700 and the key is 600. Backups (`backup`) and client configs contain secrets: store them encrypted.
- Invitation tokens contain the peer's preshared key. Pass them through stdin, a hidden prompt or a 600 file, not in chats.
- The hub's UDP port is the only thing exposed. WireGuard does not answer unauthenticated packets, so the port is invisible to scanners.
- Peers are isolated by default. Routing between peers (`--forward`) and NAT are explicit decisions.

## Limitations

- **The rollback timer does not test connectivity.** It rolls back when nobody confirmed. Automatic confirmation with `--yes` proves the interface, addresses, port and kernel peers are right, not that your service is reachable. Use `--wait-confirm` plus `confirm` from a new connection when that matters.
- **The SSH guard sees only SSH.** Sessions are found through `ss` and `sshd -T`; other services, cloud firewalls and security groups are invisible to it.
- **IPv6 forwarding is not enabled automatically** (it disables router advertisements). `doctor` warns; the decision is yours.
- **Firewall.** The port is opened only in UFW (with firewalld you get the command). Routing and NAT rules use `iptables`/`ip6tables` (the nftables backend of iptables works, pure nftables without iptables does not). Hooks are fail-open: a failing iptables rule does not stop the tunnel; `doctor` reports missing rules.
- **A restart interrupts all tunnels of the interface** for the restart plus one handshake. Peers behind NAT whose endpoint the hub does not know reconnect within their keepalive.
- **One hub per network**: no high availability and no full mesh. Rotating the hub key requires `peer set hub --key` on every peer.
- **Boot-time rollback needs the program installed** (the drop-in runs it). After uninstalling, the last written config is used.
- **The command-line messages are in Russian.** JSON output, states and exit codes are language-neutral.
- **Not verified:**
  - on virtual machines (the test host has no KVM) and on hardware: systemd is tested in containers with systemd as PID 1;
  - on Debian, RHEL and Alpine;
  - sudden power loss: `kill -9` and reboots are tested, flushing of the page cache to disk is not;
  - a successful `self-update` and `deploy --install` from GitHub: the tests have no internet access, only the failure paths are tested.
