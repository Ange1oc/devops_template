# Command reference

```
wg-network [GLOBAL OPTIONS] <command> [OPTIONS]
wg-network help                     list of commands
wg-network <command> --help         help for one command
```

Commands made of two words can be written either way: `peer add` or `peer-add`, `init hub` or `init-hub`. Aliases: `diff` = `plan`, `ls`, `list`, `peers` = `peer list`, `token` = `invite`.

All commands except `help` and `version` need root. Messages go to stderr; stdout carries only data (keys, tokens, configs, JSON), so it is safe to capture.

> The command-line interface prints its messages in Russian. Commands, options, JSON fields, states and exit codes are the same in every language and are what automation should rely on.

- [Global options](#global-options)
- [Exit codes](#exit-codes)
- [Settings file](#settings-file)
- Setting up a node: [init hub](#init-hub), [init peer](#init-peer), [join](#join), [set](#set)
- Peers (on the hub): [invite](#invite), [deploy](#deploy), [peer add](#peer-add), [peer set](#peer-set), [peer remove](#peer-remove), [peer enable / disable](#peer-enable--peer-disable), [peer list](#peer-list), [peer show](#peer-show)
- Applying and rolling back: [plan](#plan), [apply](#apply), [confirm](#confirm), [rollback](#rollback), [history](#history)
- State and diagnostics: [status](#status), [doctor](#doctor), [show](#show), [interfaces](#interfaces), [public-key](#public-key)
- Maintenance: [backup](#backup), [restore](#restore), [destroy](#destroy), [reresolve](#reresolve), [self-update](#self-update), [version](#version)
- [Installer](#installer-installsh)
- [JSON output](#json-output)

## Global options

Global options are accepted anywhere on the command line.

| Option | Meaning |
|---|---|
| `-i, --interface IFACE` | interface to work on. Default: the only managed interface; with several, `DEFAULT_INTERFACE` if it is one of them, otherwise `-i` is required |
| `-n, --dry-run` | run on a copy of the state and show the plan; the system is not changed |
| `--apply` | apply without asking (guards still work) |
| `--no-apply` | only prepare the change; apply later with `wg-network apply` |
| `-y, --yes` | answer "yes" to every question, including typed confirmations; confirm automatically after the post-checks unless SSH is affected |
| `--force` | lift a guard block (level 2) or override a refusal; confirmation and the rollback timer remain |
| `--wait-confirm` | never confirm automatically, even with `--yes`: wait for `wg-network confirm` |
| `--confirm-timeout N` | seconds before an unconfirmed change is rolled back (default `CONFIRM_TIMEOUT`, 0 disables the timer) |
| `--diff` | also print the diff of the config (secrets masked) |
| `-q, --quiet` | print only warnings and errors |
| `--no-color` | no colors (also when `NO_COLOR` is set or stderr is not a terminal) |
| `-V, --version` | same as `version` |
| `-h, --help` | help |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success, including "prepared but not applied" and "applied, waiting for confirmation" |
| 1 | error |
| 2 | invalid arguments, or `--dry-run` with a command that does not support it |
| 3 | refused by a guard or by the user |
| 4 | the change was not applied: it failed or was not confirmed, and the previous configuration was restored |
| 5 | busy: another wg-network holds the lock, or a change is waiting for confirmation |
| 6 | `peer add --wait`, `deploy`: applied, but no handshake within the timeout |
| 10 | `plan`: there are unapplied changes |
| 129, 130, 143 | interrupted by SIGHUP, SIGINT, SIGTERM (the transaction is rolled back) |

`doctor` has its own codes: 0 all good, 1 warnings, 2 errors.

The outcome of a change is also printed in words: `применено` (applied), `применено, ждёт подтверждения` (applied, waiting for confirmation), `записано в конфиг, интерфейс остановлен` (written, interface stopped), `сохранено, но НЕ применено` (prepared), `dry-run`. In JSON the same outcome is `applied`, `pending`, `written`, `prepared`, `dry-run`.

## Settings file

`/etc/default/wg-network` is optional. Format `KEY=VALUE`; the file is parsed, never executed, and every value is validated.

| Key | Default | Meaning |
|---|---|---|
| `DEFAULT_INTERFACE` | `wg0` | interface when `-i` is not given and nothing else decides |
| `DEFAULT_HUB_ADDRESS` | `10.50.0.1/24` | hub address and network for `init hub` |
| `DEFAULT_PORT` | `51820` | UDP port for `init hub` |
| `DEFAULT_KEEPALIVE` | `25` | `PersistentKeepalive` of peers towards the hub and of generated clients |
| `CONFIRM_TIMEOUT` | `120` | seconds to confirm a change; 0 disables the rollback timer |
| `AUTO_APPLY` | `ask` | `ask`: ask before applying; `hot`: apply hot changes without asking; `never`: only prepare |
| `SNAPSHOT_KEEP` | `30` | snapshots kept per interface |
| `LOCK_WAIT` | `30` | seconds to wait for the interface lock |
| `RERESOLVE_AFTER` | `135` | seconds without a handshake before a DNS endpoint is resolved again |

## Setting up a node

### init hub

```
wg-network [-i IFACE] init hub --endpoint HOST[:PORT] [options]
```

Turns this server into the hub of a network.

| Option | Meaning |
|---|---|
| `--endpoint HOST[:PORT]` | **required.** Public IP or DNS name peers connect to. The port defaults to `--port`; a different port is accepted with a warning (port forwarding) |
| `--address IP/LEN` | hub address and network size, prefix 8–30 (default `10.50.0.1/24`) |
| `--address6 CIDR\|auto` | enable dual-stack IPv6. `auto` picks a random ULA /64 (RFC 4193); a bare network such as `fd00::/64` becomes `fd00::1/64` |
| `--port N` | UDP port (default 51820) |
| `--forward` | route traffic between peers through the hub (default: peers see only the hub) |
| `--nat IFACE` | let peers reach the internet through `IFACE` (MASQUERADE, exit node) |
| `--mtu N` | tunnel MTU, 1280–9000 (default: computed by `wg-quick`) |
| `--table auto\|off\|N` | `wg-quick` `Table=`: where routes go |
| `--name NAME` | node name (default `hub`) |
| `--no-firewall` | do not open the port in UFW |
| `--force` | re-initialize a managed interface (the key and peers are kept) or replace a foreign config |

Behaviour:

- Refuses when the interface is already managed (use `set`, or `--force` to re-initialize), when a foreign `<iface>.conf` or interface exists, when the port is busy or when the network overlaps a local route.
- Installs `wireguard-tools` through `apt-get` if missing.
- Generates the key once; re-initialization with `--force` keeps it.
- Starts the interface under the rollback timer, enables `wg-quick@<iface>` at boot and installs the boot-time rollback drop-in.
- Opens the UDP port in UFW if UFW is active (and remembers it in `FIREWALL_PORT`). With firewalld it prints the command instead.

Routing (`--forward`, `--nat`) is done with per-interface forwarding sysctls and iptables rules in `PostUp`/`PostDown`, tagged with the comment `wg-network`. TCP MSS is clamped to the path MTU. The global `ip_forward` is not changed.

### init peer

```
wg-network [-i IFACE] init peer --name NAME --address IP --hub-key KEY --endpoint HOST:PORT [options]
```

Connects this server to a hub without a token (when you have the values at hand). `join` is usually easier.

| Option | Meaning |
|---|---|
| `--name NAME` | **required.** Name of this server in the network |
| `--address IP` | **required.** Tunnel IPv4 address of this server (`--ip` is an alias) |
| `--address6 IP` | tunnel IPv6 address, when the network is dual-stack |
| `--hub-key KEY` | **required.** Public key of the hub (`wg-network public-key` on the hub) |
| `--endpoint HOST:PORT` | **required.** Public endpoint of the hub |
| `--routes CIDR,...` | what to send through the hub (default: the hub address from `DEFAULT_HUB_ADDRESS`, as /32) |
| `--psk-file FILE` | file with the preshared key, if the hub uses one for this peer |
| `--keepalive N` | `PersistentKeepalive`, 0 disables (default 25) |
| `--mtu N`, `--table T` | as for `init hub` |
| `--force` | re-initialize this node |

Prints the `peer add` command to run on the hub (with `--address`).

### join

```
wg-network [-i IFACE] join [TOKEN | - | --token-file FILE] [--json] [--force]
```

Connects this server to a hub using a token from `invite`.

- Without an argument the token is read from a hidden prompt, or from stdin if stdin is not a terminal.
- `-` reads the token from stdin: `printf '%s\n' "$TOKEN" | sudo wg-network join -`.
- `--token-file FILE` reads it from a file.
- A token given as an argument works but prints a warning: arguments are visible to other users through `ps`.
- `--json` prints a summary to stdout (see [JSON output](#json-output)).
- `--force` re-initializes a node that is already managed.

The token is validated field by field. The interface is started under the rollback timer. With `--dry-run` the plan is shown, but no `peer add` command is printed: the key it would contain belongs to the sandbox, not to this server.

### set

```
wg-network [-i IFACE] set [options]
```

Changes node parameters.

| Option | Node | Meaning |
|---|---|---|
| `--endpoint HOST[:PORT]` | hub | public endpoint written into new invitations. Running peers are not affected |
| `--port N` | hub | UDP port. Every peer then needs `peer set hub --endpoint HOST:N`. With existing peers you must type the interface name (or use `--yes`) |
| `--forward on\|off` | hub | routing between peers |
| `--nat IFACE\|off` | hub | internet access for peers through `IFACE` |
| `--mtu N\|auto` | any | tunnel MTU |
| `--table auto\|off\|N` | any | `wg-quick` `Table=` |
| `--no-firewall` | hub | do not open the new port in UFW |

Almost every option changes `[Interface]`, so applying restarts the interface under the rollback timer. Changing `--forward` does not change routes already given to existing peers; adjust them with `peer set hub --routes ...` on each peer. The old UFW rule is not removed after a port change; remove it when peers have moved.

## Peers

### invite

```
wg-network [-i IFACE] invite NAME [options]
```

On the hub: reserves an address for a new server and prints the commands to run there plus the token.

| Option | Meaning |
|---|---|
| `--address IP` | address of the new peer (default: the first free one) |
| `--routes CIDR,...` | networks behind this peer (site-to-site); the hub will route them into it |
| `--full-tunnel` | the peer sends all its traffic through the hub (requires `--nat` on the hub, or `--force`) |
| `--keepalive N` | `PersistentKeepalive` on the peer side (default 25) |
| `--no-psk` | no preshared key |
| `--comment TEXT` | comment |
| `--json` | print a summary with the token to stdout |

The reservation does not appear in the config until `peer add`; the address stays taken for other invitations. Running `invite` again for a reserved name re-issues the token with the same address and preshared key. A peer's IPv6 address (dual-stack) is derived from its IPv4 host number: `10.50.0.7` gives `<prefix>::7`.

### deploy

```
wg-network [-i IFACE] deploy NAME [USER@]HOST [options]
```

On the hub: connects a remote server in one command over SSH: `invite`, optional installation, `join` on the remote server, `peer add` here, and waiting for the handshake.

| Option | Meaning |
|---|---|
| `--install` | install wg-network on the remote server first |
| `--remote-iface IFACE` | interface on the remote server (default `wg0`) |
| `--ssh-option OPT` | an `ssh -o` option, repeatable: `--ssh-option Port=2222` |
| `--routes`, `--full-tunnel`, `--keepalive N`, `--no-psk`, `--comment TEXT` | as for `invite` |
| `--wait N` | wait up to N seconds for the handshake (default 20, 0 does not wait) |

Requirements: key-based SSH (`BatchMode=yes`, connection timeout 15 s) as root or as a user with password-less `sudo` (`sudo -n`). The token goes through the stdin of the SSH session. If the installation or the join fails, the reservation is removed. If the remote side prepared the change but did not apply it (for example, a guard there asked for confirmation), the reservation is kept and the error says so. Exit 6 means the peer was added but no handshake happened in time. `--dry-run` is not supported.

### peer add

```
wg-network [-i IFACE] peer add NAME (--key KEY | --generate) [options]
```

On the hub: adds a peer, or completes an invitation.

| Option | Meaning |
|---|---|
| `--key KEY` | the peer's public key (printed by `join`/`init peer`) |
| `--generate` | generate the keys here and output a ready client config (for laptops and phones; the private key is not stored on the hub) |
| `--address IP` | address (default: from the invitation, otherwise the first free one) |
| `--routes CIDR,...` | networks behind this peer |
| `--psk` / `--no-psk` | preshared key. Default: yes for `--generate`, otherwise as in the invitation |
| `--endpoint HOST:PORT` | the peer's address, when the hub must initiate the connection |
| `--keepalive N` | `PersistentKeepalive` from the hub side (usually not needed) |
| `--comment TEXT` | comment |
| `--wait N` | wait up to N seconds for the first handshake; exit 6 if none |
| `--json` | print a summary to stdout |
| `--output FILE` | `--generate` only: write the client config to FILE (mode 600; an existing file needs `--force`) |
| `--qr` | `--generate` only: show a QR code (needs `qrencode`) |
| `--dns IP[,IP]` | `--generate` only: DNS servers for the client |
| `--full-tunnel` | `--generate` only: send all client traffic through the hub (needs NAT on the hub) |

Adding a peer is a hot change: other tunnels are not interrupted. Refused when the name exists (use `peer set`), when the key belongs to another peer or to the hub, or when the address or routes conflict.

### peer set

```
wg-network [-i IFACE] peer set NAME [options]
```

Changes a peer. On a peer node the hub record is called `hub`.

| Option | Meaning |
|---|---|
| `--key KEY` | new public key (a reinstalled server) |
| `--routes CIDR,...\|none` | networks behind the peer; `none` removes them. On a peer node: what to send through the hub (at least one route must remain) |
| `--endpoint HOST:PORT\|none` | the peer's endpoint. On a peer node: the new address of the hub |
| `--keepalive N` | `PersistentKeepalive`, 0 disables |
| `--comment TEXT` | comment |
| `--rotate-psk` | generate a new preshared key and print it to stdout; it must also be set on the peer itself |
| `--psk-file FILE\|-` | set the preshared key from a file or stdin (the other half of a rotation) |

Examples:

```bash
sudo wg-network peer set hub --endpoint 198.51.100.20:51820   # on a peer: the hub moved
sudo wg-network peer set office --routes 192.168.10.0/24,192.168.20.0/24
ssh hub sudo wg-network peer set worker1 --rotate-psk --yes | ssh worker1 sudo wg-network peer set hub --psk-file - --yes
```

### peer remove

```
wg-network [-i IFACE] peer remove NAME
```

Removes a peer or an invitation. The peer is disconnected as soon as the change is applied; other tunnels continue. The record stays in the snapshot: `wg-network rollback` brings it back, and its last known endpoint is used to reconnect immediately.

### peer enable / peer disable

```
wg-network [-i IFACE] peer disable NAME
wg-network [-i IFACE] peer enable NAME
```

Disables a peer while keeping its settings (it disappears from the config), or enables it again. An invitation that was not completed cannot be enabled or disabled.

### peer list

```
wg-network [-i IFACE] peer list [--json]
```

Table `NAME ADDRESS STATE ENDPOINT HANDSHAKE RX TX ROUTES`.

| State | Meaning |
|---|---|
| `online` | last handshake not older than 3 minutes |
| `stale` | older than 3 minutes: unreachable or idle |
| `no-handshake` | never connected |
| `down` | the interface is not running |
| `disabled` | disabled with `peer disable` |
| `invited` | reserved with `invite`, waiting for `peer add` |

### peer show

```
wg-network [-i IFACE] peer show NAME
```

Details of one peer: state, public key, whether a preshared key is set, addresses, AllowedIPs, endpoint, keepalive, last handshake, traffic, comment, creation time.

## Applying and rolling back

### plan

```
wg-network [-i IFACE] plan [--diff]
```

Compares the live config with the config rendered from the state and shows the changes, the way they would be applied and the guard warnings. Changes nothing. Exit 0: nothing to apply (including a difference in form only, such as a new header after an upgrade, which the next apply rewrites without touching the interface); exit 10: there are unapplied changes (useful for monitoring and CI). Also warns about manual edits and a pending confirmation.

### apply

```
wg-network [-i IFACE] apply [--start] [--diff]
```

Applies prepared changes. Running `apply` counts as approval; guards still ask for their own confirmation. `--start` also starts a stopped interface (otherwise a stopped interface only gets its file written). `apply` also brings the kernel back to the config when someone changed peers with `wg set`.

### confirm

```
wg-network [-i IFACE] confirm
```

Confirms an applied change and cancels the rollback timer. Run it from a **new** SSH session: that proves access works after the change.

### rollback

```
wg-network [-i IFACE] rollback              an unconfirmed change: now; otherwise the latest snapshot
wg-network [-i IFACE] rollback SNAPSHOT     return to a snapshot (see history)
```

- With a change waiting for confirmation, `rollback` restores the previous config and the previous state immediately.
- Otherwise `rollback` returns the desired state to the latest snapshot and applies it like any change (plan, guards, timer). Because a snapshot is taken before every change, this undoes the last change; running it again undoes the rollback.
- `rollback SNAPSHOT` returns to any snapshot from `history`, including a `rejected` one (a change that failed or was not confirmed), which is how you retry it.
- A snapshot taken before the interface existed cannot be restored; use `destroy` to remove an interface.

Service modes used by the timer and at boot: `--pending [--txid ID] [--auto | --boot]`.

### history

```
wg-network [-i IFACE] history
```

Lists snapshots, newest first, with the operation they preceded (`peer-add`, `set`, `rollback`, `rejected`, ...). The snapshot id contains its date and time.

## State and diagnostics

### status

```
wg-network [-i IFACE] status [--json]
```

Interface and systemd state, role, name, public key, addresses, endpoint and port, routing mode, MTU and table; warnings about a pending confirmation, manual edits, unapplied changes or a damaged state; then the peer table.

### doctor

```
wg-network [-i IFACE] doctor
```

A read-only self-check. Exit 0 all good, 1 warnings, 2 errors.

| Section | Checks |
|---|---|
| Environment | `wg`, `wg-quick`, `ip`, `ss`, `flock`; the `wireguard` kernel module; a running `wireguard-go` (slow userspace); systemd; NTP synchronization |
| State | validation of every file; permissions 700/600; an interrupted transaction; a pending confirmation; overlapping AllowedIPs |
| Config | presence and permissions of the live config; manual edits; unapplied changes; `wg-quick@` enabled at boot; the boot rollback drop-in |
| Interface | running; kernel peers equal the config; listen port; routes for AllowedIPs; MTU above 1420 |
| Network and firewall | UFW or `INPUT DROP` rules for the port; forwarding sysctls; FORWARD, MASQUERADE and MSS rules; global IPv6 forwarding for dual-stack routing; conntrack usage on an exit node; SSH sessions through the interface |
| Peers | state and handshake age of every peer; DNS resolution of endpoints with a hostname |

### show

```
wg-network [-i IFACE] show [--candidate] [--reveal]
```

Prints the live config (`--candidate`: the config the next `apply` would write). `PrivateKey` and `PresharedKey` are masked unless `--reveal` is given.

### interfaces

```
wg-network interfaces
```

All managed interfaces: `IFACE ROLE ADDRESS STATE PEERS`.

### public-key

```
wg-network [-i IFACE] public-key
```

Prints the public key of the interface (stdout only).

## Maintenance

### backup

```
wg-network [-i IFACE] backup [--output FILE]
```

Writes a tar archive of the state: `node.env`, `private.key`, `peers.d`, and `meta.env` (format `wgn-backup-1`). Without `--output` the archive goes to stdout, which must not be a terminal. The archive contains the private key and preshared keys: keep it encrypted, for example `wg-network backup | gpg -c > wg0.backup.gpg`. `--output` creates the file with mode 600 and refuses an existing file or symlink unless `--force` is given.

### restore

```
wg-network [-i IFACE] restore FILE|- [--force] [--no-firewall]
```

Restores an interface from a backup, typically on a replacement server. The archive must contain only state files (no absolute paths, `..`, symlinks or devices) and is validated with the same rules as a live state before anything is written. The interface is then started under the usual plan, guards and timer. A managed interface is replaced only with `--force`; its current state stays in a snapshot. The server gets the same key, so peers reconnect as soon as the hub's DNS name points to it.

### destroy

```
wg-network -i IFACE destroy
```

Stops and disables the interface, archives its state and config to `/var/backups/wg-network/<iface>-<time>.tar` (mode 600) and removes them, including the boot drop-in. The interface must be named explicitly with `-i`, and you must type its name (or use `--yes`). A pending confirmation is cancelled. A UFW rule opened by wg-network is left in place; the command to remove it is printed.

### reresolve

```
wg-network reresolve
```

WireGuard resolves a DNS endpoint only once. For every enabled peer with a hostname endpoint and no handshake for `RERESOLVE_AFTER` seconds, the endpoint is set again, which resolves it anew (like `reresolve-dns` from wireguard-tools). Runs every minute from `wg-network-reresolve.timer` in a hardened unit; you rarely need to run it by hand.

### self-update

```
wg-network self-update [--ref REF]
```

Reinstalls wg-network from the repository and ref it was installed from (or `--ref`). Only the program changes: keys, configs and interfaces are untouched. Undo with `sudo /opt/wg-network/install.sh --rollback`.

### version

```
wg-network version
```

Version, installation path, repository, ref, commit, installation time and the `wireguard-tools` version.

## Installer (install.sh)

```
install.sh [--ref REF] [--repo OWNER/REPO] [--local [DIR]] [--rollback] [--uninstall]
```

| Option | Meaning |
|---|---|
| `--ref REF` | branch, tag or commit to install (default `main`) |
| `--repo OWNER/REPO` | another repository, for a fork (default `Ange1oc/devops_template`) |
| `--local [DIR]` | install from a local checkout (default: the directory of `install.sh`) |
| `--rollback` | switch back to the previous version in `/opt/wg-network.old` |
| `--uninstall` | remove the program, units and drop-ins; interfaces keep running, the state stays in `/etc/wireguard/wg-network` |

Environment: `WGN_REPO`, `WGN_REF` set the defaults; `GITHUB_TOKEN` gives access to a private repository (needs `curl`; the token is passed through a header file, not the command line). Two installations cannot run at the same time.

## JSON output

All JSON goes to stdout as one object or array per command.

`invite --json`:

```json
{"name":"worker1","address":"10.50.0.2","address6":"","token":"wgn1....","install_command":"curl -fsSL ... | sudo bash -s -- --ref main","join_command":"sudo wg-network join"}
```

`join --json`:

```json
{"name":"worker1","address":"10.50.0.2","public_key":"...","interface":"wg0","result":"applied","approve_command":"sudo wg-network peer add worker1 --key ..."}
```

`peer add --json` (`handshake` is `true`/`false` with `--wait`, otherwise `null`):

```json
{"name":"worker1","address":"10.50.0.2","public_key":"...","result":"applied","handshake":true}
```

`peer list --json`: an array of peers:

```json
[{"name":"worker1","public_key":"...","address":"10.50.0.2","address6":"","routes":"","endpoint":"203.0.113.21:43122","state":"online","latest_handshake":1767225600,"rx_bytes":1234,"tx_bytes":5678,"comment":""}]
```

`status --json`:

```json
{"interface":"wg0","role":"hub","name":"hub","public_key":"...","address":"10.50.0.1/24","address6":"",
 "listen_port":51820,"endpoint":"vpn.example.com:51820","forward":false,"nat":"","unit":"active","up":true,
 "state_valid":true,"pending_confirmation":false,"manual_edits":false,"unapplied_changes":false,"peers":[...]}
```

`latest_handshake` is a Unix time, 0 for "never", and `null` when the interface is down or the peer is not in the kernel (invited, disabled). `state_valid` is `false` when a state file is damaged; `unapplied_changes` is then `false` because no plan can be built.
