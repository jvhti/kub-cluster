# Technitium DNS: jvos.dev split-horizon zone (LAN)

**Not managed by ArgoCD/kubectl — Technitium runs outside the cluster
entirely.** This is a reference doc only; the zones themselves are the
source of truth, maintained by hand via Technitium's UI or API.

There are two clustered Technitium nodes (see "Cluster" below): the
**primary** `dns1.jvos.dev` at `192.168.1.252:5380` / `10.0.0.2:5380`, and
the **secondary** `dns2.jvos.dev` at `192.168.1.253:5380` /
`10.0.0.3:5380`. Either answers the same zones, so a LAN device can use
either address as its resolver. Both names resolve to those addresses out
of the `jvos.dev` zone itself — the cluster manages the records for its own
nodes (see "Cluster" below).

## Why this exists

Same underlying problem `infrastructure/networking/coredns-custom/` solves
for pods: the router has no hairpin NAT, so a LAN client resolving
`*.jvos.dev` via public DNS gets the WAN IP back, then hangs/times out (or,
confirmed live, sometimes gets served the *wrong* backend instead of timing
out) trying to connect to that IP from inside the LAN. `coredns-custom`
fixes this for pods; this Technitium zone does the same for any LAN device
that uses Technitium as its DNS server (which is not automatic — a device
needs its DHCP-assigned or manually-configured DNS server to actually be
`192.168.1.252`).

## What it is

A **Primary** zone for `jvos.dev` in Technitium (replicated to the
secondary node as a `Secondary` zone — see "Cluster" below), authoritative
(not a conditional forwarder) — this server never forwards `*.jvos.dev`
queries upstream once the zone exists, same effective behavior as
`coredns-custom`'s `hosts { ... fallthrough }` block. A records point
`*.jvos.dev` hostnames straight at the internal Cilium Gateway VIPs
(`192.168.1.240` for everything routed via `gateway-internal`'s HTTPRoutes,
`192.168.1.241` for `headscale.jvos.dev` specifically, which uses its own
Gateway/TLSRoute — see `infrastructure/controllers/headscale/gateway.yaml`
for why).

## Cluster (primary + secondary)

Added 2026-09-17. Technitium's own clustering (v14+) keeps the second node
in sync — both are standalone Proxmox LXCs, unrelated to the k3s cluster:

| | Primary | Secondary |
|---|---|---|
| LXC | `124 technitiumdns` on `ra` | `141 technitiumdns2` on `osiris` |
| LAN / internal addrs | `192.168.1.252`, `10.0.0.2` | `192.168.1.253`, `10.0.0.3` |
| `dnsServerDomain` | `dns1.jvos.dev` | `dns2.jvos.dev` |
| Config dir / unit | `/etc/dns`, `technitium.service` | `/etc/dns`, `dns.service` |

(The `124`/`141` LXC hostnames are still `technitiumdns`/`technitiumdns2` —
Proxmox hostnames, unrelated to `dnsServerDomain`, and unchanged by the
rename below.)

- Cluster domain is **`jvos.dev`** (it was `home.litb.com.br` until the
  rename below). The init creates the catalog zone
  **`cluster-catalog.jvos.dev`** — that membership list is what drives
  replication. HTTPS (self-signed, `:53443`) is required for node-to-node
  sync and is enabled by the init; `webServiceHttpToTlsRedirect` is
  intentionally left `false` so the plain-HTTP `:5380` API the commands
  below use keeps working.
- **A node's `dnsServerDomain` must end with the cluster domain** — the API
  rejects anything else (*"DNS server domain name must end with the cluster
  domain name"*) — and `clusterDomain` itself is fixed at init: there's no
  API to change it (`setOptions` only sets heartbeat/config intervals). So
  the node names are only *within* `jvos.dev`, and renaming them meant
  rebuilding the cluster (procedure below).
- The init also creates — or reuses, if it already exists — the **cluster
  primary zone**, named as the cluster domain, so `jvos.dev` here. That's
  the same user-facing split-horizon zone described above *and* where the
  cluster keeps its own node records (`dns1`/`dns2.jvos.dev` A + the
  `_53443._tcp.…` DANE TLSA records for them). It's an ordinary zone, so
  the hand-maintained records below coexist with those — just don't touch
  the cluster-managed ones.
- **Zones only replicate if they're members of the catalog zone** —
  `jvos.dev` and `home.litb.com.br` are registered with
  `POST /api/zones/options/set?zone=<zone>&catalog=cluster-catalog.jvos.dev`
  and exist as `Secondary` zones on `dns2` (SOA serial tracks the
  primary's). `home.litb.com.br` is still the LAN zone for
  `*.home.litb.com.br`, it's just no longer the cluster domain. Anything not
  in the catalog stays primary-only. Corollary: **edit zone records on the
  primary only** — the secondary's copies are read-only. DHCP is not synced
  (there are no DHCP scopes here anyway), and node-specific options
  (`dnsServerLocalEndPoints`, TLS certs) are per-node by design.
- Health/membership: `GET /api/admin/cluster/state?token=<TOKEN>`. Upstream
  docs: [blog.technitium.com — understanding
  clustering](https://blog.technitium.com/2025/11/understanding-clustering-and-how-to.html)
  and `APIDOCS.md` in the Technitium repo.
- Zone updates reach the secondary by DNS NOTIFY (primary → secondaries),
  falling back to the member zones' SOA refresh (900s). Right after a fresh
  join the primary may log `failed to notify name server ... (RCODE=Refused)`
  for zones the secondary hasn't provisioned yet — transient, it clears
  itself. The primary notifies the secondary from *each* of its addresses
  (`192.168.1.252` and `10.0.0.2`), while the freshly-created secondary zone
  initially only knows the address it joined through, so the notifies from
  the other address are refused until the zone's master list catches up —
  same transient. If propagation ever looks stuck, check `notifyFailed` /
  `notifyFailedFor` in the primary's `/api/zones/list` and compare SOA
  serials on both nodes.
- **Adding another node**: `POST /api/admin/cluster/initJoin` on the *new*
  node (`Content-Type: application/x-www-form-urlencoded`), with
  `secondaryNodeIpAddresses=<its addrs>`, `ignoreCertificateErrors=true`,
  the `cluster-sync` credentials below, and `primaryNodeUrl` — which
  **must be the primary's domain name** (`https%3A%2F%2Fdns1.jvos.dev%3A53443%2F`),
  not an IP (the API rejects an IP outright). Pass
  `primaryNodeIpAddress=192.168.1.252` explicitly too: a fresh node has no
  internal zone yet and can otherwise resolve the primary's name to its
  *public* IP. If the joining node already has a `dnsServerDomain` that
  ends with the cluster domain, the join **keeps** it (so set
  `dnsServerDomain` before joining to choose the node's name); otherwise it
  becomes `<its hostname>.<clusterDomain>`. Note the join **replaces the
  joining node's Administration section** with the primary's
  (users/settings), which also disables the default `admin`/`admin` login on
  a fresh install.
- To upgrade, avoid the official installer on a node whose unit isn't
  `dns.service` (it would create a second unit): back up `/etc/dns`, then
  extract
  [DnsServerPortable.tar.gz](https://download.technitium.com/dns/DnsServerPortable.tar.gz)
  over `/opt/technitium/dns` and restart the existing unit.

### Renaming a node / the cluster: 2026-09-17 (`home.litb.com.br` → `jvos.dev`)

The nodes were `dns.home.litb.com.br` (primary) and
`technitiumdns2.home.litb.com.br` (secondary), under cluster domain
`home.litb.com.br`. Getting to `dns1`/`dns2.jvos.dev` meant changing the
cluster domain, and since `clusterDomain` is fixed at init the whole cluster
had to be rebuilt. Done in this order, backups first (`/root/tdns-backup/`,
tarballs of `/etc/dns`), DNS answering throughout (each node keeps serving
its own zones; only cluster sync pauses):

1. On the secondary: `POST /api/admin/cluster/secondary/leave`. It loses its
   cluster config *and* its catalog/member zones (they come back on
   re-join) — expect it to serve nothing but recursion in between.
2. On the primary: `POST /api/admin/cluster/primary/delete?forceDelete=false`
   (`force` isn't needed once no secondaries remain).
3. `POST /api/settings/set?dnsServerDomain=dns1.jvos.dev` on the primary and
   `…=dns2.jvos.dev` on the secondary — only accepted while unclustered.
   Setting the domain **reissues the node's self-signed web cert
   automatically**, no restart: `/etc/dns/self-signed-cert.pfx` is rewritten
   and `:53443` immediately serves the new name.
4. On the primary: `POST /api/admin/cluster/init?clusterDomain=jvos.dev&primaryNodeIpAddresses=192.168.1.252,10.0.0.2`.
   It reuses the existing `jvos.dev` zone as the cluster primary zone and
   creates `cluster-catalog.jvos.dev`.
5. Re-register the member zones against the new catalog (the
   `zones/options/set?catalog=…` call in the bullets above) — the catalog
   zone is new, so membership doesn't carry over.
6. On the secondary: `initJoin` as in the bullets above.
7. Clean up the old cluster's leftovers: deleting the cluster does **not**
   remove the old node records it had put in `home.litb.com.br`
   (`dns.home.litb.com.br` A records and its `_53443._tcp.…` TLSA) — they
   have to be deleted by hand.

Two things that did *not* follow the domain change on their own:

- **The Block Page app** binds `:80`/`:443` on each node and has its own
  root cert at `/etc/dns/apps/Block Page/self-signed-cert.pfx`, which is
  *not* reissued when the domain changes. It kept signing its 7-day `:443`
  leaves (correct subject) with the **old-name root**, so hitting
  `https://192.168.1.252/` chained up to `dns.home.litb.com.br`/the old
  hostname. Fix: delete that file and restart the unit (`technitium.service`
  on `dns1`, `dns.service` on `dns2`) — it regenerates for the current
  domain. (`:443` is this app; the admin console/API is `:5380`, TLS
  `:53443`.)
- The secondary doesn't answer DNS for the catalog zone itself
  (`cluster-catalog.jvos.dev` has no SOA over `:53` on `dns2`, unlike on the
  primary) — it's a `SecondaryCatalog` provisioning zone, not a served one.
  Replication is still fine; verify it via `zones/list` + member-zone
  serials instead.

## Why not external-dns + a Technitium webhook

Considered and rejected in favor of this simpler static approach. A
Technitium webhook for external-dns exists
([roosmaa/external-dns-technitium-webhook](https://github.com/roosmaa/external-dns-technitium-webhook))
and would make this genuinely automatic (new HTTPRoutes/TLSRoutes get LAN
records with zero manual step), but needs: a second external-dns instance
(the existing one already targets Cloudflare for public DNS — one instance
can't target two providers), a `--target-template` override or a full
second instance per Gateway VIP (`.240` vs `.241` can't be distinguished by
a single flat template), a third-party webhook sidecar, and real Technitium
credentials in a cluster Secret. All solvable, but meaningfully more
complexity for the same end result a hand-maintained zone gets more simply
— and `coredns-custom` already requires the same manual-update-on-new-app
discipline, so this isn't a new maintenance burden, just the same one
applied to a second DNS server.

## Records (as of 2026-09-14, hubble UI)

All TTL 300s. Keep this list in sync with `coredns-custom.yaml`'s `hosts`
block — same set of hostnames, same targets. This is the hand-maintained
set only; the zone also carries the cluster's own managed records
(`dns1`/`dns2.jvos.dev` + their DANE TLSA, NS/SOA) — leave those alone.

| Hostname | Target |
|---|---|
| `jvos.dev` | `192.168.1.240` |
| `argocd.jvos.dev` | `192.168.1.240` |
| `auth.jvos.dev` | `192.168.1.240` |
| `gitea.jvos.dev` | `192.168.1.240` |
| `headscale-admin.jvos.dev` | `192.168.1.240` |
| `alertmanager.jvos.dev` | `192.168.1.240` |
| `grafana.jvos.dev` | `192.168.1.240` |
| `prometheus.jvos.dev` | `192.168.1.240` |
| `longhorn.jvos.dev` | `192.168.1.240` |
| `fotos.jvos.dev` | `192.168.1.240` |
| `prowlarr.jvos.dev` | `192.168.1.240` |
| `qbittorrent.jvos.dev` | `192.168.1.240` |
| `sonarr.jvos.dev` | `192.168.1.240` |
| `radarr.jvos.dev` | `192.168.1.240` |
| `bazarr.jvos.dev` | `192.168.1.240` |
| `jellyfin.jvos.dev` | `192.168.1.240` |
| `jellyseerr.jvos.dev` | `192.168.1.240` |
| `jellystat.jvos.dev` | `192.168.1.240` |
| `books.jvos.dev` | `192.168.1.240` |
| `paperless.jvos.dev` | `192.168.1.240` |
| `search.jvos.dev` | `192.168.1.240` |
| `search-mcp.jvos.dev` | `192.168.1.240` |
| `memos.jvos.dev` | `192.168.1.240` |
| `memos-mcp.jvos.dev` | `192.168.1.240` |
| `picoclaw.jvos.dev` | `192.168.1.240` |
| `start.jvos.dev` | `192.168.1.240` |
| `chat.jvos.dev` | `192.168.1.240` |
| `status.jvos.dev` | `192.168.1.240` |
| `draw.jvos.dev` | `192.168.1.240` |
| `frigate.jvos.dev` | `192.168.1.240` |
| `hubble.jvos.dev` | `192.168.1.240` |
| `browser.jvos.dev` | `192.168.1.240` |
| `headscale.jvos.dev` | `192.168.1.241` |

## Adding a new hostname later

Whenever a new `HTTPRoute`/`TLSRoute` is added under `infrastructure/` or
`applications/`, add the matching record here too (same target VIP as the
Gateway it attaches to) and to `coredns-custom.yaml`'s `hosts` block. Via
the Technitium API (needs a user with Zones Modify permission, or
Administrators group membership), **on the primary** — catalog replication
propagates it to the secondary by itself:

```
curl "http://192.168.1.252:5380/api/zones/records/add?token=<TOKEN>&domain=<new>.jvos.dev&zone=jvos.dev&type=A&ipAddress=192.168.1.240&ttl=300"
```

Get a token via `POST /api/user/login?user=<user>&pass=<pass>`.

## The `external-dns` user

A dedicated Technitium user (`external-dns`) was created for this work,
currently a member of the **Administrators** group (broader than strictly
needed — the per-permission `Zones: Modify` checkbox alone didn't appear to
reflect in the login response's `permissions` field even after being set,
though this wasn't fully root-caused; Administrators group membership was
used instead and confirmed working). Credentials are not recorded here —
retrieve/rotate them directly in Technitium's UI (Administration → Users).
Despite the name, this user isn't actually driving `external-dns` — the
webhook approach was rejected (see above) — the name was chosen before that
decision and left as-is since renaming a Technitium user isn't
straightforward via the UI.

## The `cluster-sync` user

A second dedicated user (`cluster-sync`, also in the **Administrators**
group), created 2026-09-17, used only for cluster operations: `initJoin`
requires a primary-side administrator's username/password and there's no
token-based alternative. Created with `/api/admin/users/create`, then
`/api/admin/users/set?user=cluster-sync&memberOfGroups=Administrators`.

Because the Administration section is part of cluster sync, the user exists
on both nodes. Its password is kept on the k8s cluster as the
`technitium-cluster-user` Secret in the `default` namespace — the reference
shape and read-back/rotation commands are in this directory's
`technitium-cluster-user-secret.yaml`. Read it with:

```
kubectl get secret technitium-cluster-user -n default \
  -o jsonpath='{.data.password}' | base64 -d
```
