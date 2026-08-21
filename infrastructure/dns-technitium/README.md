# Technitium DNS: jvos.dev split-horizon zone (LAN)

**Not managed by ArgoCD/kubectl — Technitium runs outside the cluster
entirely** (`192.168.1.252:5380` / `10.0.0.2:5380`). This is a reference doc
only; the zone itself is the source of truth, maintained by hand via
Technitium's UI or API.

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

A **Primary** zone for `jvos.dev` in Technitium, authoritative (not a
conditional forwarder) — this server never forwards `*.jvos.dev` queries
upstream once the zone exists, same effective behavior as
`coredns-custom`'s `hosts { ... fallthrough }` block. A records point
`*.jvos.dev` hostnames straight at the internal Cilium Gateway VIPs
(`192.168.1.240` for everything routed via `gateway-internal`'s HTTPRoutes,
`192.168.1.241` for `headscale.jvos.dev` specifically, which uses its own
Gateway/TLSRoute — see `infrastructure/controllers/headscale/gateway.yaml`
for why).

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

## Records (as of 2026-08-21, sonarr/radarr/bazarr migration)

All TTL 300s. Keep this list in sync with `coredns-custom.yaml`'s `hosts`
block — same set of hostnames, same targets.

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
| `headscale.jvos.dev` | `192.168.1.241` |

## Adding a new hostname later

Whenever a new `HTTPRoute`/`TLSRoute` is added under `infrastructure/` or
`applications/`, add the matching record here too (same target VIP as the
Gateway it attaches to) and to `coredns-custom.yaml`'s `hosts` block. Via
the Technitium API (needs a user with Zones Modify permission, or
Administrators group membership):

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
