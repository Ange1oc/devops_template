# How it works

This page explains the model behind wg-network: what it stores, how a change travels from a command to the kernel, and which mechanisms protect a running VPN and your SSH access. Read it once before using wg-network on production servers.

- [Topology and roles](#topology-and-roles)
- [Desired state and the live config](#desired-state-and-the-live-config)
- [The life of a change](#the-life-of-a-change)
- [How a plan is applied](#how-a-plan-is-applied)
- [Approval](#approval)
- [Confirmation and the rollback timer](#confirmation-and-the-rollback-timer)
- [Guards](#guards)
- [Transactions, snapshots and history](#transactions-snapshots-and-history)
- [Manual edits (drift)](#manual-edits-drift)
- [Dry run](#dry-run)
- [Secrets](#secrets)
- [Validation](#validation)
- [Invitation tokens](#invitation-tokens)
- [Files and directories](#files-and-directories)
- [Migration from earlier versions](#migration-from-earlier-versions)

## Topology and roles

wg-network builds a **star** (hub and spoke):

```
               ┌──────────── hub 10.50.0.1 ────────────┐
               │   public endpoint vpn.example.com:51820│
               └───▲───────────▲───────────▲────────────┘
                   │           │           │
              worker1      office       phone
             10.50.0.2    10.50.0.3   10.50.0.4
                         + 192.168.10.0/24
```

- The **hub** has a public endpoint and a tunnel network (for example `10.50.0.0/24`). It knows every peer.
- A **peer** knows only the hub. It sends to the hub the networks listed in its routes: only the hub address, the whole tunnel network, or everything (`0.0.0.0/0`, full tunnel).
- Peers talk to each other only through the hub and only when the hub forwards (`set --forward on`). By default they are isolated.
- A peer may announce networks behind it (site-to-site): the hub then routes those networks into that peer.

One server can take part in several networks, each on its own interface (`wg0`, `wg1`, ...), and can be a hub in one and a peer in another. Every command works on one interface, chosen with `-i IFACE` or automatically when only one is managed.

## Desired state and the live config

wg-network separates **what you want** from **what runs**:

| | Where | Who writes it |
|---|---|---|
| Desired state | `/etc/wireguard/wg-network/<iface>/` (`node.env`, `private.key`, `peers.d/*.env`) | wg-network commands |
| Live config | `/etc/wireguard/<iface>.conf` | rendered from the state, written only when a change is applied |
| Kernel | the `wg0` interface, its peers and routes | `wg-quick` / `wg syncconf` from the live config |

The live config is a derived file. It is self-contained and never calls wg-network, so tunnels keep working after wg-network is removed. Editing it by hand is detected (see [drift](#manual-edits-drift)).

State files are `KEY=VALUE` text. They are **parsed, never sourced**, and validated on every load: a damaged or tampered file cannot turn into a config.

## The life of a change

Every command that changes something follows the same path:

```
 command (peer add, set, ...)
        │
        ▼
 1. lock the interface ────────────────────── busy? exit 5
 2. snapshot the current state
 3. change the desired state
        │
        ▼
 4. plan: live config vs. config rendered from the new state
        │
        ├── guards: SSH sessions, routes, foreign VPNs, manual edits
        ├── approval: question / --apply / --yes / AUTO_APPLY
        ▼
 5. apply: hot | restart | start | offline | rewrite
        │
        ▼
 6. post-checks: interface, addresses, port, peers in the kernel
        │
        ├── failed? roll back at once, exit 4
        ▼
 7. confirmation (when the change can cut access) or done
```

If the command is interrupted at any point (an error, Ctrl+C, `kill`, a dropped SSH session), the state is restored from the snapshot of step 2. After `kill -9` the next run of wg-network restores it.

`wg-network plan` shows steps 4 and the guard warnings without changing anything. `--no-apply` stops after step 4: the change is saved ("prepared") and can be applied later with `wg-network apply`.

## How a plan is applied

wg-network compares the **canonical form** of the live and the new config: comments and formatting are dropped, peers are matched by public key, AllowedIPs are sorted. A new header or a different order therefore never causes a restart. From the difference it picks the least disruptive way to apply it:

| Class | When | What happens |
|---|---|---|
| `hot` | only `[Peer]` sections change | `wg syncconf` plus route synchronization. Sessions of unchanged peers continue without a single lost packet. Afterwards the kernel is compared with the config (keys, AllowedIPs, preshared keys, keepalive). |
| `restart` | `[Interface]` changes (address, port, MTU, table, hooks) or a `/0` route appears or disappears | The interface goes down **with the old config** (its `PostDown` removes the old firewall rules), the new file is written, the interface goes up. All its tunnels pause for 1–3 seconds. Runs under the rollback timer. |
| `start` | the interface is not running and is being started (`init`, `apply --start`, `restore`) | Start under the rollback timer. |
| `offline` | the interface was stopped by the administrator | The file is written, the interface is **not** started. Use `apply --start` to start it. |
| `rewrite` | the meaning is unchanged (for example, a new version header) | Only the file is rewritten. |
| `hot` (resync) | the config equals the state, but the kernel differs (someone used `wg set`) | `apply` brings the kernel back to the config. |

Details worth knowing:

- **Old firewall rules are always removed.** A plain `systemctl restart` after writing a new file would run the *new* `PostDown`, and the old FORWARD/MASQUERADE rules would stay in iptables forever. wg-network stops with the old config first.
- **Routes during hot changes.** `wg syncconf` does not touch routes, so wg-network adds and removes them itself, with the same rules as `wg-quick`. `/0` routes need `wg-quick`'s policy routing and always go through a restart.
- **The listen port is pinned.** On a peer node the config has no `ListenPort`; `wg syncconf` would pick a new random port and the hub would keep sending to the old one until the next keepalive. wg-network keeps the current port.
- **Fast reconnect.** After a restart the hub does not know where its peers are until they send something, which can take ~15 s. wg-network restores the last known endpoints and starts the handshake itself, so tunnels come back within milliseconds. The same happens to peers returning through `peer enable` or a rollback.

## Approval

A planned change is applied when one of these is true:

- `--apply` or `--yes` is given, or the command is `wg-network apply`;
- the class is `rewrite` (nothing changes in practice);
- the class is `hot` and `AUTO_APPLY=hot` is set in `/etc/default/wg-network`;
- you answer `y` to the question (only with a terminal on stdin).

Otherwise the change stays prepared. Without a terminal the answer is always "no", which is the safe default for scripts. `AUTO_APPLY=never` prepares every change and applies nothing until `wg-network apply`.

A guard of level 1 asks for more than `y`: you have to type the interface name. A guard of level 2 blocks the change until `--force` is given. See [Guards](#guards).

## Confirmation and the rollback timer

A change that can cut connectivity (`restart`, `start`, and `hot` when a guard raised a warning) is applied **unconfirmed**, like `netplan try`:

1. Before applying, wg-network saves the previous config and arms a **rollback timer** for `CONFIRM_TIMEOUT` seconds (120 by default, `--confirm-timeout N` per command). The timer is a transient systemd unit outside your SSH session; without systemd it is a separate process in its own session. If the timer cannot be armed, nothing is applied.
2. The change is applied and checked.
3. You confirm that you still have access:
   - in an interactive session type `yes` at the countdown prompt;
   - or run `sudo wg-network confirm` from **a new SSH session** (the better proof that access works);
   - with `--yes` the change is confirmed automatically after the post-checks, **unless** a guard found that it affects an SSH session, or `--wait-confirm` is given.
4. If nobody confirms in time, the timer restores the previous config.

What else triggers a rollback:

| Event | Result |
|---|---|
| The SSH session drops while the prompt is waiting | the waiting process restores the previous config immediately |
| The server reboots before confirmation | the `ExecStartPre` drop-in of `wg-quick@<iface>` brings up the previous config at boot |
| You run `wg-network rollback` | immediate rollback |
| Post-checks fail (interface missing, wrong address or port, kernel differs) | immediate rollback, exit 4 |

While a change waits for confirmation, all other changes of that interface are refused (exit 5).

A rollback restores **both** the live config and the desired state. The rejected state is kept as a snapshot labelled `rejected`, so you can inspect it or try again with `wg-network rollback <id>`. This prevents a later, unrelated command from silently re-applying a change that was just rejected.

What the timer does **not** do: it does not test connectivity itself. It only rolls back when nobody confirmed. Automatic confirmation with `--yes` proves that the interface, its addresses, port and peers are correct, not that your service is reachable. When that matters use `--wait-confirm` and confirm from a new connection:

```bash
ssh server sudo wg-network set --mtu 1380 --yes --wait-confirm --confirm-timeout 60
ssh server sudo wg-network confirm   # a new connection; if it cannot connect, the change is rolled back in 60 s
```

`--confirm-timeout 0` disables the timer: the change is applied without confirmation. Use it only when you have out-of-band access.

## Guards

Guards analyse every plan before it is applied. Level 0 means safe, level 1 asks for a typed confirmation and arms the timer, level 2 blocks the change until `--force`. Even with `--force` the confirmation and the timer remain.

### SSH access

wg-network finds **all** established SSH sessions, not only yours: listening ports come from `sshd -T` and from `ss` (the `sshd` process), sessions from `ss`, plus `$SSH_CONNECTION` (which `sudo` usually does not pass). For each session it checks the plan:

| Situation | Level |
|---|---|
| a new route would capture the traffic to the SSH client (for example `0.0.0.0/0` on a server, or the administrator's network behind a peer). Longest-prefix match and the way `wg-quick` installs `/0` routes are taken into account | 2, blocked |
| a hot change removes, disables or modifies the peer an SSH session goes through | 2, blocked |
| the interface an SSH session goes through will restart | 1, typed confirmation and timer |

A session "goes through" the interface when its local address belongs to the interface, or when replies to the client leave through it (a client behind a peer connected to the server's public address).

### Foreign VPNs and networks

| Check | When | Result |
|---|---|---|
| `/etc/wireguard/<iface>.conf` exists and was not created by wg-network | `init`, `join`, `restore` | refused; `--force` replaces it and keeps a backup |
| an interface with that name already exists | same | refused; `--force` overrides |
| the UDP port is in use | `init hub`, `set --port`, `restore` | refused |
| the tunnel network overlaps a route of the server (LAN, Docker, another VPN) | `init hub` | refused; `--force` overrides |
| a route behind a peer overlaps a local route | `invite`, `peer add`, `peer set`, `init peer` | refused; `--force` overrides |
| a route overlaps another peer's address or route | same | refused (WireGuard would silently give the address to one peer) |
| a route overlaps the hub network, or a `/0` route on the hub | same | refused |
| `--full-tunnel` on a hub without NAT | `invite`, `peer add` | refused; `--force` overrides |

## Transactions, snapshots and history

Every change runs in a **transaction**:

1. The interface lock is taken (`flock`, waits `LOCK_WAIT` seconds, then exit 5).
2. A snapshot of the state and the live config is written to `snapshots/<date>-<time>-<label>.tar`.
3. `tx.env` records the transaction.
4. On success `tx.env` is removed and old snapshots beyond `SNAPSHOT_KEEP` (30) are pruned.
5. On failure the state is restored from the snapshot and the snapshot is removed (it equals the state again). If the process was killed, the next run finds `tx.env` and restores the state before doing anything else.

`wg-network history` lists snapshots with the operation they preceded. `wg-network rollback` without arguments returns to the latest snapshot, which undoes the last change; running it again undoes the rollback itself. `wg-network rollback <id>` returns to any snapshot. A rollback to a snapshot is an ordinary change: plan, guards, confirmation and its own snapshot.

A refused operation never pushes real restore points out: pruning happens only after a successful change.

## Manual edits (drift)

wg-network stores the SHA-256 of every config it writes (`rendered.sha256`). If the live file no longer matches:

- and the edit does not change the meaning compared to the new config, the file is simply rewritten;
- otherwise applying is refused (exit 3). `wg-network plan --diff` shows the difference. `--force` overwrites the file and saves the manual version to `/var/backups/wg-network/<iface>.conf.manual.<time>`.

## Dry run

`-n` / `--dry-run` runs the command on a **copy of the state** in a temporary directory and shows the plan and the guard warnings. Nothing on the system changes: not the files, the kernel, the routes, the firewall or the systemd units. The test suite verifies this for every changing command by fingerprinting all of them before and after.

Commands that cannot run on a copy (`confirm`, `destroy`, `deploy`, `backup`, `reresolve`, `self-update`) refuse `--dry-run` with exit 2 instead of silently ignoring it. Read-only commands (`status`, `plan`, `show`, ...) accept it and behave as usual.

## Secrets

- Private keys never appear in command lines, logs or the audit trail, and no temporary copy survives the command.
- Files with secrets (client configs, backups) are created with mode 600 from the first byte and never through an existing file or a symlink, so a planted link cannot make root write a key somewhere else.
- `wg-network show` masks `PrivateKey` and `PresharedKey` unless `--reveal` is given; `plan --diff` always masks them.
- Tokens and `GITHUB_TOKEN` are never passed as arguments to child processes.
- The state directory is 700, key and config files are 600.

## Validation

Everything that ends up in a config or a file name is validated:

| Value | Rule |
|---|---|
| Key | exactly 32 bytes in base64 (44 characters ending with `=`) |
| IPv4 | dotted quad without leading zeros (`010` would be octal) |
| IPv6 | RFC 4291 text, normalized to RFC 5952; embedded IPv4 and zone ids are rejected |
| Route | a network address: `10.0.0.5/24` is rejected with the hint `10.0.0.0/24` |
| Hub address | a host address with prefix /8 to /30 (IPv4) or /48 to /96 (IPv6) |
| Endpoint | `HOST:PORT` or `[IPv6]:PORT`, port 1–65535, host is an IP or a hostname |
| MTU | 1280–9000 (1280 is the IPv6 minimum) |
| Table | `auto`, `off` or 1–4294967295 except 253–255 |
| Name | 1–32 characters `A-Z a-z 0-9 . _ -`, starting with a letter or a digit |
| Comment | up to 64 printable characters without `"`, `\`, `` ` `` and `$` |

It is therefore impossible to inject an extra line (for example `PostUp = ...`) through an argument.

## Invitation tokens

`invite` produces a token `wgn1.<base64url>` that carries `KEY=VALUE` lines: the peer's name and addresses, the hub key and endpoint, the routes to send through the hub, the preshared key, keepalive and MTU. `join` accepts only these keys and validates every value. Because the token contains the preshared key, treat it as a secret: `join` reads it from a hidden prompt, stdin or a file; an argument works but prints a warning.

## Files and directories

```
/opt/wg-network/                       the program (/usr/local/bin/wg-network is a symlink)
/opt/wg-network.old/                   the previous version, for install.sh --rollback
/etc/default/wg-network                settings (optional, KEY=VALUE)
/etc/wireguard/<iface>.conf            rendered config, 600, self-contained
/etc/wireguard/wg-network/             700
    .lock.<iface>                      the interface lock
    <iface>/                           state of one interface, 700
        node.env                       role and interface parameters
        private.key                    interface private key, 600
        peers.d/<name>.env             one file per peer (on a peer node: the record "hub")
        snapshots/*.tar                snapshots before every change
        rendered.sha256                hash of the last written config (drift detection)
        tx.env                         unfinished transaction
        pending.env                    applied, unconfirmed change
        pending.prev.conf              the config to return to
        endpoints.cache                last known peer endpoints (fast reconnect)
        last-tx.env                    outcome of recent unconfirmed changes
/etc/systemd/system/wg-quick@<iface>.service.d/wg-network.conf   rollback at boot
/etc/systemd/system/wg-network-reresolve.{service,timer}         DNS re-resolution
/etc/bash_completion.d/wg-network      completion
/var/backups/wg-network/               destroy archives, manual config versions
```

`node.env` keys: `SCHEMA ROLE NAME ADDRESS ADDRESS6 LISTEN_PORT ENDPOINT MTU TABLE FORWARD NAT FIREWALL_PORT CREATED_AT`.
Peer keys: `PUBLIC_KEY PSK ADDRESS ADDRESS6 ROUTES ENDPOINT KEEPALIVE ENABLED PENDING COMMENT CREATED_AT UPDATED_AT`.

Prefer commands over editing these files. If you do edit them, `wg-network doctor` and every command validate them again.

## Migration from earlier versions

The original `wg-network.sh` (v0: `role.env` and ready config fragments in `peers.d/*.conf`) and the first modular version (v1: `role.env` and `peers.d/*.env`) are migrated automatically on the first run of any command as root:

- the key, addresses and peers are carried over unchanged;
- the new state is built aside and moved into place only when it is complete and valid, so a failed migration leaves the old files untouched and can be retried;
- if the running config has the same meaning as the migrated one, it is adopted without restarting the interface;
- old files are moved to `/etc/wireguard/wg-network/legacy-<time>/`.
