# DMZ forwarder (192.168.1.239)

**Not managed by ArgoCD — lives outside k3s entirely, as a Proxmox LXC.**
These files are a reference copy only; the live source of truth is the
LXC itself. If you change something live, copy it back here too.

## Why this exists

The home router only supports a single DMZ host, not per-port forwarding
(confirmed: no port-forward option available, only DMZ). A DMZ forwards
*all* inbound ports/protocols to one internal IP.

Before this box existed, the DMZ pointed straight at
`192.168.1.240` — the Cilium-managed LoadBalancer VIP for
`gateway-internal` (see `infrastructure/networking/gateway/`). That
worked for HTTP(S) but made it impossible to add anything else
externally reachable (e.g. WireGuard), because:

- Cilium's LB-IPAM assigns each VIP to exactly **one** Service —
  confirmed live by testing a second Service requesting the same IP on a
  disjoint port (UDP 51820 vs TCP 80/443): it was rejected outright
  (`already_allocated`), regardless of `CiliumLoadBalancerIPPool`
  `serviceSelector` scoping. There's no way to make Cilium fan one VIP
  out to multiple Services/ports.
- `CiliumLoadBalancerIPPool` ranges can't overlap even with disjoint
  selectors either (see the pool-conflict comment in
  `infrastructure/networking/gateway/ip-pool.yaml`).
- The Gateway API's generated Service is reconciler-owned; hand-editing
  its listeners/ports is what caused the documented Cilium v1.19.1 bug
  that silently broke every `*.jvos.dev` app (see
  `infrastructure/controllers/headscale/gateway.yaml`'s comment) — not a
  change worth risking again for this.

So: this LXC is now the DMZ target instead, and it fans traffic back out
internally to whatever port/protocol combo actually needs it — the one
thing a plain router DMZ can't do on its own.

## What it does

```
Internet -> router DMZ -> 192.168.1.239 (this LXC)
                              |
                              +-- TCP 80/443  -> HAProxy -> 192.168.1.240:80/443 (Cilium Gateway VIP)
                              +-- UDP 51820   -> nftables DNAT -> <k3s node>:<NodePort> (WireGuard, once deployed)
```

- **HAProxy** (`haproxy.cfg`) handles TCP only, pure `mode tcp`
  passthrough — no TLS termination here, the Gateway still owns that.
- **nftables** (`nftables.nft`) handles UDP, because HAProxy has no
  general raw-UDP relay capability (confirmed: this build has `-QUIC`,
  and even QUIC support would only cover HTTP/3, not arbitrary UDP
  protocols like WireGuard).
- **HAProxy Data Plane API** (`dataplaneapi.yml`) gives a REST API for
  adding/editing forwards without hand-editing the config file over SSH
  each time. Bound to `127.0.0.1:8080` only — access it via an SSH
  tunnel from this box, never expose it on the LAN/eth0 interface.

## Box details

- Proxmox LXC, Alpine Linux 3.22, `192.168.1.239/24`, hostname `haproxy`.
- HAProxy + Data Plane API installed via native `apk` packages
  (`haproxy`, `haproxy-dataplaneapi` — both musl-native, no `gcompat`
  needed), not upstream binaries.
- SSH hardened: key-only auth (`PasswordAuthentication no`,
  `PermitRootLogin prohibit-password`) — see
  `/etc/ssh/sshd_config.d/hardening.conf` on the box.
- `net.ipv4.ip_forward=1` (was already on by default in this LXC
  template).

## Updating the WireGuard stub

`nftables.nft`'s DNAT rule points at a placeholder
(`10.1.0.2:31820`, kub-ctrl-1) that doesn't exist yet. Once the
in-cluster WireGuard Service is deployed:

1. Get its real NodePort: `kubectl get svc -n <ns> <name> -o
   jsonpath='{.spec.ports[0].nodePort}'`
2. Update both the `dnat to` and `masquerade` port in `nftables.nft`
   (here and on the live box: `/etc/nftables.nft`), then
   `nft -f /etc/nftables.nft` to reload.
3. Any of the three k3s nodes work as the DNAT target — NodePort
   listens identically on all of them.

## Data Plane API credentials

`dataplaneapi.yml.example` here is a sanitized template — the real
`dataplaneapi.yml` (with the actual bcrypt password hash) lives only on
the box at `/etc/haproxy/dataplaneapi.yml`, not in git, same as
`headplane-credentials` in the headscale setup. Generate a new hash with
`htpasswd -nbB admin '<password>'` (Alpine's `mkpasswd` — BusyBox — has
no bcrypt option, `apache2-utils`' `htpasswd` does).
