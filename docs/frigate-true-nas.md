# Frigate on TrueNAS: exposing it through the cluster

Frigate 0.17.2 runs as a **TrueNAS app** on the TrueNAS box (`10.0.0.5`),
not in this cluster. It is exposed as `frigate.jvos.dev` through the same
Authelia-backed oauth2-proxy login gate as every other public app, but the
hop from the proxy to TrueNAS needed a design that a normal in-cluster app
doesn't. This doc records the why — especially the port-binding trap —
before anyone "simplifies" it away.

## The topology trap

TrueNAS's NIC `enp6s0` carries **two** address families on the same
physical port (confirmed via `GET /api/v2.0/interface`):

- `10.0.0.5/8` — the "management" network the k3s cluster sits on
- `192.168.1.12/24` — the **LAN**

So the LAN and the cluster's management network are **one flat L2**. Any
LAN device (phone, laptop) can reach `10.0.0.5` directly — `ping` and TCP
both work from a LAN vantage point, no router hop involved.

Frigate's published host port `30193` (container `8971`) is therefore
directly reachable from the LAN — and in 0.17.2, with `auth.enabled: false`
(which is required for the proxy-header design below), a direct hit on
`10.0.0.5:30193` is **full admin access with no password** (role resolves
to `admin` via `proxy.default_role`, user falls back to `viewer`).

The obvious-looking fix — restrict the TrueNAS published port with
`host_ips` (the app's `network.web_port.host_ips`, settable via
`PUT /api/v2.0/app/id/frigate`) — **cannot work here**:

- `host_ips` must be an IP on a **TrueNAS** interface. The only candidates
  are `10.0.0.5` and `192.168.1.12` — both on the same flat L2 as the
  LAN, so binding either one blocks nothing.
- The IPs that would actually matter as a source-restriction (the k3s
  nodes' `10.1.0.x` egress addresses, or the `kube-client` box's
  `10.1.254.254`) don't exist on TrueNAS at all — and a bind address
  doesn't filter *source* IPs anyway; it only selects which local address
  the listener binds to. Docker refuses to bind a published port to a
  non-local address.

(Also worth knowing: frigate's internal-port auth bypass —
`x-server-port: 5000` in its `auth()` function — is **not** spoofable:
its nginx `auth_location.conf` strips all client headers on the `/auth`
subrequest and sets `X-Server-Port` from its own `$server_port`. And the
internal port `5000` is not published, only `30193` is.)

## The actual design

The boundary is a **secret**, not a network position:

1. `infrastructure/controllers/oauth2-proxy-frigate/` — a dedicated
   oauth2-proxy instance (one per app, same pattern as the Longhorn/degoog
   siblings) fronting `frigate.jvos.dev`, doing the Authelia OIDC login
   gate and setting `X-Auth-Request-User` (`set-xauthrequest`).
2. An **nginx "injector" sidecar** in the same pod (the chart's
   `extraContainers`), listening on `127.0.0.1:30194` only. oauth2-proxy's
   `--upstream` points at the sidecar, not at `10.0.0.5` directly.
3. The sidecar is the only component holding the proxy secret
   (`frigate-proxy-secret` Secret, imperative) and adds
   `X-Proxy-Secret: <secret>` on every hop to `10.0.0.5:30193`, with TLS
   verification off (frigate's self-signed `CN=*` "FRIGATE DEFAULT
   CERT").
4. Frigate's `config.yaml` (on TrueNAS) sets `proxy.auth_secret` to the
   same value. Its `/auth` endpoint 401s **any** request without a
   matching `X-Proxy-Secret` — including every direct LAN hit, because
   frigate's own nginx copies `X-Proxy-Secret` into the `/auth`
   subrequest (its `proxy_trusted_headers.conf` lists it).

Net effect: LAN can reach `10.0.0.5:30193` but gets 401 on everything;
only the authenticated public path (gateway → oauth2-proxy → injector →
TrueNAS) gets admin, and only as the Authelia-validated user
(`proxy.header_map.user: X-Auth-Request-User` → `remote-user`,
`proxy.default_role: admin`).

### Frigate config block (TrueNAS, not in git)

Appended to `/mnt/General/frigate/config/config.yaml` via the TrueNAS
filesystem API (see `docs/truenas-app-migrations.md` for the API
patterns — note `filesystem.get` returns an empty body; use the
`core.download` job trick instead):

```yaml
auth:
  enabled: false
proxy:
  auth_secret: <same value as the frigate-proxy-secret Secret's proxy-secret key>
  default_role: admin
  header_map:
    user: X-Auth-Request-User
```

Note: `auth.roles` must NOT be given `admin`/`viewer` keys in 0.17.2 —
its config validator rejects reserved role names; `admin`/`viewer` are
forced in internally, which is what makes `default_role: admin` valid.
Changing the config requires a frigate restart
(`POST /api/v2.0/app/redeploy` body `"frigate"`).

## In-cluster trust note

Any in-cluster pod can still reach `10.0.0.5:30193` (management network),
but without the secret it gets 401 everywhere — same posture as a LAN
client. The secret itself lives in a cluster Secret, so cluster-internal
actors who can read Secrets in `oauth2-proxy-frigate` can read it; that's
the same trust level as any other credential in this cluster.

## Rotating the proxy secret

The value exists in exactly two places: the `frigate-proxy-secret` Secret
and frigate's `config.yaml` on TrueNAS. Rotate **both, then restart**:

1. `NEW=$(openssl rand -hex 32)`
2. `kubectl create secret generic frigate-proxy-secret -n oauth2-proxy-frigate --from-literal=proxy-secret="$NEW" --dry-run=client -o yaml | kubectl apply -f -`
3. Append/replace `proxy.auth_secret: "$NEW"` in `/mnt/General/frigate/config/config.yaml` via the TrueNAS filesystem API (multipart `POST /api/v2.0/filesystem/put`, `data` part = `{"path": ...}`, `file` part = new content), then `POST /api/v2.0/app/redeploy` body `"frigate"`.
4. `kubectl rollout restart deploy/oauth2-proxy-frigate -n oauth2-proxy-frigate` (the sidecar env is fixed at pod start).

Rotate the **OIDC client-secret** separately per `docs/oauth2-proxy-authelia.md`
(`authelia-oidc-client-frigate` + `oauth2-proxy-frigate-credentials`,
same pair-regeneration procedure as the other instances).
