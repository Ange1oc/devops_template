# Scenarios

Recipes for typical networks. Every recipe assumes a hub created with `wg-network init hub` (see [Getting started](getting-started.md)) and the default network `10.50.0.0/24`. Add `--dry-run` to any changing command to see its plan first.

- [Servers that only talk to the hub](#servers-that-only-talk-to-the-hub)
- [Routing between peers](#routing-between-peers)
- [Site-to-site: a LAN behind a peer](#site-to-site-a-lan-behind-a-peer)
- [Exit node: internet through the hub](#exit-node-internet-through-the-hub)
- [Laptops and phones](#laptops-and-phones)
- [IPv6 dual-stack](#ipv6-dual-stack)
- [Several networks on one server](#several-networks-on-one-server)
- [A hub with a DNS name and changing IP](#a-hub-with-a-dns-name-and-changing-ip)
- [Moving the hub to another IP or port](#moving-the-hub-to-another-ip-or-port)
- [A reinstalled peer (new key)](#a-reinstalled-peer-new-key)
- [Rotating preshared keys](#rotating-preshared-keys)
- [Replacing a failed hub](#replacing-a-failed-hub)
- [Temporarily disconnecting a peer](#temporarily-disconnecting-a-peer)
- [Preparing changes and applying them later](#preparing-changes-and-applying-them-later)
- [Automation: Ansible, CI, scripts](#automation-ansible-ci-scripts)
- [Migrating from wg-network.sh](#migrating-from-wg-networksh)

## Servers that only talk to the hub

The default, and the safest setup: every peer sees only the hub (for example monitoring, backups or a database on the hub).

```bash
sudo wg-network init hub --endpoint vpn.example.com          # on the hub
sudo wg-network deploy app1 root@app1.example.com --install  # on the hub, for every server
```

Each peer gets the route `10.50.0.1/32` only. Peers cannot reach each other even if they try: the hub does not forward.

## Routing between peers

```bash
sudo wg-network set --forward on
```

This restarts the hub interface under the rollback timer and adds:

- `net.ipv4.conf.wg0.forwarding=1` (only for the tunnel interface, not the global `ip_forward`);
- an iptables rule `FORWARD -i wg0 -o wg0 -j ACCEPT` tagged `wg-network`;
- TCP MSS clamping for forwarded traffic.

Peers invited **after** this change automatically get the route to the whole network (`10.50.0.0/24`). Peers that already exist keep their old route; on each of them that needs the network:

```bash
sudo wg-network peer set hub --routes 10.50.0.0/24
```

That is a hot change on the peer and does not interrupt its tunnel.

To isolate peers again: `sudo wg-network set --forward off`. The rules are removed when the interface restarts.

## Site-to-site: a LAN behind a peer

An office gateway `office` has the LAN `192.168.10.0/24` behind it, and servers in the VPN must reach it.

On the hub:

```bash
sudo wg-network set --forward on                              # if other peers need the office LAN
sudo wg-network invite office --routes 192.168.10.0/24
```

`--routes` says which networks live behind this peer. The hub adds them to the peer's AllowedIPs and routes them into the tunnel. wg-network refuses routes that overlap the hub network, other peers, or local routes of the hub (use `--force` only if the overlap is intended).

On the office gateway run the printed `join`. Then configure the gateway's LAN side yourself, because that is outside the VPN:

- enable forwarding on the gateway: `sysctl -w net.ipv4.ip_forward=1` (and persist it);
- either add a route on the office router: `10.50.0.0/24 via <gateway LAN address>`,
- or masquerade VPN traffic on the gateway: `iptables -t nat -A POSTROUTING -s 10.50.0.0/24 -o <lan-if> -j MASQUERADE`.

For the gateway to reach the whole VPN (not only the hub), it needs the route to the network: `sudo wg-network peer set hub --routes 10.50.0.0/24` on the gateway (or invite it after `--forward on`).

Add another network later on the hub: `sudo wg-network peer set office --routes 192.168.10.0/24,192.168.20.0/24`.

## Exit node: internet through the hub

Clients send all traffic through the hub and appear on the internet with the hub's address.

```bash
sudo wg-network set --nat eth0                     # the hub's internet interface
sudo wg-network peer add phone --generate --full-tunnel --dns 1.1.1.1 --qr
```

`--nat` adds MASQUERADE for the tunnel network on `eth0`, the FORWARD rules in both directions (return traffic only for established connections), per-interface forwarding on `wg0` and `eth0`, and MSS clamping. `--full-tunnel` gives the client `AllowedIPs = 0.0.0.0/0` (and `::/0` with IPv6).

For a server that should route everything through the hub, invite it with `--full-tunnel`:

```bash
sudo wg-network invite egress1 --full-tunnel
```

On that server the guard checks whether the new default route would capture your SSH session. If you are connected from the internet, the change is **blocked**: you would lose access. Connect through the VPN first, or accept the risk with `--force` (the confirmation timer still protects you).

`doctor` on the hub watches conntrack usage: an exit node with many clients can fill `nf_conntrack_max`.

## Laptops and phones

```bash
sudo wg-network peer add laptop --generate --output /root/laptop.conf
sudo wg-network peer add phone --generate --qr
```

- The keys are generated on the hub and the private key is not kept there. If the config is lost, remove the peer and add it again.
- A preshared key is added by default.
- The client gets `PersistentKeepalive = 25` so it stays reachable behind NAT.
- Without `--full-tunnel` the client sends only VPN traffic through the tunnel: the hub address, or the whole network when the hub forwards.

## IPv6 dual-stack

```bash
sudo wg-network init hub --endpoint vpn.example.com --address6 auto
```

`auto` picks a random ULA /64 as RFC 4193 recommends (`fdXX:XXXX:XXXX::/64`); you can give your own prefix (`--address6 fd00:50::/64`, prefix 48–96). The hub gets `::1`. Each peer's IPv6 address is derived from its IPv4 host number: `10.50.0.7` becomes `fdXX:XXXX:XXXX::7`. Tokens carry both addresses.

IPv6 **forwarding** is global in Linux and enabling it turns off router advertisements on the external interface (unless it has `accept_ra=2`). wg-network therefore does not enable it; `doctor` warns when dual-stack routing needs it. Enable it yourself when you are sure:

```bash
sysctl -w net.ipv6.conf.eth0.accept_ra=2     # keep accepting RA on the uplink, if you rely on it
sysctl -w net.ipv6.conf.all.forwarding=1
```

## Several networks on one server

Each network is an interface with its own state. Give every network its own interface name, address range and port:

```bash
sudo wg-network -i wg1 init hub --endpoint vpn.example.com:51821 --port 51821 --address 10.60.0.1/24
sudo wg-network -i wg1 invite db1
```

With more than one managed interface `-i` is required (unless `DEFAULT_INTERFACE` is one of them). `wg-network interfaces` lists them. A server can be a hub in one network and a peer in another; the guards stop overlapping networks.

## A hub with a DNS name and changing IP

Use a DNS name as the endpoint: `init hub --endpoint vpn.example.com`. WireGuard itself resolves a name only once, so peers would stay on the old IP after it changes. The `wg-network-reresolve.timer` on each peer checks every minute: if the hub has not answered for `RERESOLVE_AFTER` seconds (135 by default), the name is resolved again and the tunnel recovers on its own.

## Moving the hub to another IP or port

New IP with the same DNS name: nothing to do on the peers, the re-resolution timer follows the name.

New IP without DNS: on every peer (a hot change, the tunnel recovers at once):

```bash
sudo wg-network peer set hub --endpoint 198.51.100.20:51820
```

Update the hub's endpoint for future invitations: `sudo wg-network set --endpoint 198.51.100.20`.

New port: change it on the hub, then on every peer:

```bash
sudo wg-network set --port 51900 --endpoint vpn.example.com:51900   # on the hub, type the interface name to confirm
sudo wg-network peer set hub --endpoint vpn.example.com:51900       # on each peer
```

The new port is opened in UFW; the old rule stays until you remove it (`ufw delete allow 51820/udp`).

## A reinstalled peer (new key)

The server was reinstalled and has a new key. On it: `sudo wg-network join` with a fresh token from `invite`, or `init peer`. On the hub, replace the key of the existing record (the address and routes stay):

```bash
sudo wg-network peer set worker1 --key 'NEW_PUBLIC_KEY='
```

## Rotating preshared keys

The hub generates a new key and prints it to stdout; the peer takes it from stdin. Piping it between two SSH sessions keeps it out of files and command lines:

```bash
ssh hub sudo wg-network peer set worker1 --rotate-psk --yes \
  | ssh worker1 sudo wg-network peer set hub --psk-file - --yes
```

Both steps are hot changes. Until the second one is applied the peer cannot complete a new handshake; the current session keeps working for up to two minutes (WireGuard rekeys every 120 s), so run both steps together. `--psk-file FILE` reads the key from a file instead.

For a laptop or phone (keys generated with `--generate`), remove the peer and add it again to get a new config.

## Replacing a failed hub

Prepare in advance on the hub and store the archive encrypted, off the server:

```bash
sudo wg-network backup | gpg -c > hub-wg0.backup.gpg
```

On the replacement server:

```bash
curl -fsSL https://raw.githubusercontent.com/Ange1oc/devops_template/main/ubuntu/wg/install.sh | sudo bash
gpg -d hub-wg0.backup.gpg | sudo wg-network restore -
```

The archive is checked (only state files, no links or devices) and validated before anything is written. The new hub has the same key, addresses and peers. Point the DNS name to the new server (or change the endpoint on the peers) and the peers reconnect by themselves. Open the UDP port in any cloud firewall.

## Temporarily disconnecting a peer

```bash
sudo wg-network peer disable worker1     # hot, other tunnels continue
sudo wg-network peer enable worker1      # reconnects immediately using its last known endpoint
```

## Preparing changes and applying them later

Prepare several changes and apply them together, for example in a maintenance window:

```bash
sudo wg-network --no-apply peer add db1 --key ...
sudo wg-network --no-apply set --mtu 1380
sudo wg-network plan --diff           # what will change and how (exit 10: something to apply)
sudo wg-network apply                 # one apply, one confirmation
```

To prepare everything by default set `AUTO_APPLY=never` in `/etc/default/wg-network`.

## Automation: Ansible, CI, scripts

Useful properties:

- without a terminal nothing is applied unless `--yes` or `--apply` is given;
- stdout carries only data, messages go to stderr;
- [exit codes](commands.md#exit-codes) are stable; `plan` returns 10 when something is pending, `doctor` returns 0/1/2;
- `--json` is available for `invite`, `join`, `peer add`, `peer list`, `status`;
- tokens can be passed through stdin.

A complete join from a controller that can reach both machines:

```bash
TOKEN=$(ssh hub sudo wg-network invite worker1 --json | jq -r .token)
KEY=$(printf '%s\n' "$TOKEN" | ssh worker1 sudo wg-network join - --yes --json | jq -r .public_key)
ssh hub sudo wg-network peer add worker1 --key "$KEY" --yes --wait 20 --json
```

Or simply `ssh hub sudo wg-network deploy worker1 root@worker1 --yes`.

`--yes` confirms changes automatically after the post-checks. When a change could break the controller's own access, require a confirmation from a new connection:

```bash
ssh server sudo wg-network set --mtu 1380 --yes --wait-confirm --confirm-timeout 60
ssh server sudo wg-network confirm
```

If the second connection fails, the change is rolled back after 60 seconds.

Idempotency: `init` on a managed interface returns 3 (refused), `peer add` for an existing name returns 3. Check first with `wg-network status --json` or `peer show NAME` (exit 1 when the peer does not exist).

## Migrating from wg-network.sh

Install wg-network on a server that runs the old script and run any command, for example `sudo wg-network status`. The state is migrated automatically (see [How it works](concepts.md#migration-from-earlier-versions)): keys, addresses and peers stay, and the running interface is not restarted when its config has the same meaning. Check the result with `sudo wg-network plan`; exit code 0 means the migrated state matches what is running.
