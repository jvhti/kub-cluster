# Migrating an app off TrueNAS SCALE and into the cluster

A runbook for moving a TrueNAS app-catalog app (Docker Compose under the
hood, in SCALE's "Dragonfish"+ apps system) onto k3s, keeping bulk data on
TrueNAS via NFS where that's actually safe to do (see the SQLite/NFS
caveat below — not everything should stay on NFS). Written up after
doing this for Immich (see `applications/immich/` and its commit history)
and later the gluetun/prowlarr/qbittorrent/sonarr/radarr/bazarr *arr
stack (see `applications/arr-stack/`, gluetun-fronted apps sharing its
netns vs. plain standalone Deployments, and the NFS-to-Longhorn config
fix); generalize from there rather than treating every detail below as
gospel for every app.

## When storage should stay on TrueNAS vs. move to nfs-csi

TrueNAS apps typically store data as either **bind mounts** to a path
under a ZFS dataset (e.g. `/mnt/General/<app>/uploads`) or **ix-volumes**
(docker-managed volumes under `/mnt/.ix-apps/docker/volumes/...`, opaque
and not meant to be touched directly). Check the app's config
(`GET /api/v2.0/app/id/<name>` on TrueNAS's REST API — see "Talking to
the TrueNAS API" below) for `active_workloads.container_details[].volume_mounts`
to see which is which.

- **Bind-mounted, dataset-backed data you want to keep in place**: add a
  static `PersistentVolume` pointing at the existing NFS export (or a new
  one — see below), same idea as `applications/immich/storage.yaml`. No
  data copy needed, and the ZFS dataset (snapshots, quotas, etc.) keeps
  working exactly as before.
- **ix-volumes, or anything you're fine re-provisioning fresh**: let
  `infrastructure/storage/csi-driver-nfs`'s `nfs-csi` StorageClass
  dynamically provision a new subdirectory instead. Simpler manifest, but
  means copying data in by hand if there's anything worth keeping (`kubectl
  cp` or a scratch pod mounting both old and new paths with `rsync`).

## Don't put a WAL-mode SQLite db on NFS

Even for a bind-mounted, dataset-backed config dir you'd otherwise keep
in place per the rule above: if the app keeps a SQLite database in
`/config` (Sonarr/Radarr/Bazarr and most of the `*arr` family do —
`sonarr.db`, `radarr.db`, `bazarr.db` under `/config/` or `/config/db/`),
put that PVC on `nfs-csi`'s dynamic-provisioning sibling class or,
better, **`longhorn`** instead — not a static PV over the NFS export,
even though the export works fine for every other app's config in this
repo (prowlarr, qbittorrent, immich's upload dir, etc).

Why: those apps run SQLite in WAL mode, which needs real mmap + byte-range
file locking — NFS doesn't reliably provide either. Confirmed live
migrating sonarr/radarr/bazarr (see `applications/arr-stack/`): within
minutes of going live on NFS-backed config, `radarr.db`'s header was
found zeroed out (unrecoverable — restored from the app's own
`Backups/scheduled/*.zip`, see below) and `sonarr.db` intermittently threw
`disk I/O error` / `file is not a database` under normal use (logging in
via the UI was enough to trigger it). `PRAGMA integrity_check` on the
live NFS-mounted file can *pass* one moment and the header can be zeroed
the next — don't treat one clean check as proof the file is safe to keep
running on NFS.

The fix is `storageClassName: longhorn` (dynamic provisioning, no static
PV/export needed) for just the config PVC, keeping any bulk media/data
mount on NFS as before — media is plain file I/O, not a database, so it
doesn't hit this problem. See `applications/arr-stack/storage.yaml`'s
sonarr/radarr/bazarr PVCs for the concrete pattern, and its
`sonarr-radarr-bazarr.yaml` Deployments for why `strategy.type: Recreate`
still matters even on Longhorn (a RWO volume can't attach to two pods at
once during a RollingUpdate either).

Migrating an already-broken NFS-backed config to Longhorn: scale the
Deployment to 0 first (**commit the `replicas: 0` change and push it** —
a live `kubectl scale` gets reverted by ArgoCD's `selfHeal` on its next
sync, see CLAUDE.md), then use a scratch pod that mounts both the old NFS
export and the new PVC to copy data across (see the scratch-pod pattern
below) — run it as root (or match the image's actual non-root default
user explicitly via `runAsUser: 0`; some images like `keinos/sqlite3`
default to a non-root user even when the Pod's `securityContext` is
omitted) so it can read the NFS side, `chown -R` the target back to the
app's real uid/gid (580 in this repo's convention) afterward, then
restore `replicas: 1` the same committed way.

## Scheduled backup zips as a recovery source

Sonarr/Radarr/Bazarr (and likely the rest of the `*arr` family) keep
their own periodic backups as zip files under
`<config>/Backups/scheduled/*.zip` (each containing `config.xml`,
`<app>.db`, and an `INFO` file) — a few days' worth by default,
independent of anything TrueNAS or this repo manages. Confirmed live:
when `radarr.db` was found corrupted (see above), the most recent
scheduled backup was less than a day old and restored cleanly
(`PRAGMA integrity_check: ok`, correct row count). Worth checking for
before assuming a corrupted `*arr` database means starting the library
over — extract with `unzip`, verify with `sqlite3 <app>.db "PRAGMA
integrity_check;"` before trusting it, then swap it in for the live
`.db` (removing any stale `.db-wal`/`.db-shm` siblings alongside it too).

## NFS exports: only child datasets, not parent directories

`infrastructure/storage/csi-driver-nfs`'s existing exports
(`General/pi`, `General/longhorn`) are each their own ZFS dataset, not a
parent directory containing sub-datasets. This matters: exporting a
*parent* directory that contains child ZFS datasets (e.g.
`/mnt/General/immich` when `immich/uploads` and `immich/db` are separate
datasets under it) mounts with a bare "permission denied" from the NFS
client — no useful client-side error, no server-side rejection reason
visible over the API either. Confirmed live during the Immich migration:
switching the export to the child dataset path directly
(`/mnt/General/immich/uploads`) fixed it immediately with an identical
`maproot_user`/`networks` config. Always export the specific dataset you
need, not a directory above it.

Also confirmed live: the k3s **node's own** `mount -t nfs` (bare `mount`
command over SSH) failed with "permission denied" even against a
correctly-exported child dataset — but a **pod** mounting the same
export via a plain `nfs:` volume worked immediately. The node's NFS
client tooling (`mount.nfs`/`mount.nfs4` helpers) appears incomplete on
this OS image; don't debug from the bare node, test through a scratch pod
instead (see the pattern below).

### Adding a new export (TrueNAS REST API)

Same API key convention as `infrastructure/storage/truenas-api-key-secret.yaml`
(a live Secret, not committed — see that file's header for how to fetch a
usable key). From the k3s node (TrueNAS isn't reachable from a dev
machine without VPN — see CLAUDE.md's access notes):

```
KEY=<the api key, e.g. read from the truenas-api-key Secret in-cluster>
curl -s -k -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d '{
  "path": "/mnt/General/<app>/<dataset>",
  "networks": ["10.0.0.0/8"],
  "maproot_user": "root",
  "maproot_group": "wheel",
  "enabled": true
}' 'https://10.0.0.5/api/v2.0/sharing/nfs'
```

`maproot_user: root` matches the existing `General/pi` share. If the
export is only needed temporarily (e.g. to reach a database's raw data
files for a one-time dump, not for the app's ongoing storage), delete it
again afterward: `DELETE /api/v2.0/sharing/nfs/id/<id>`.

**Missing `maproot_user`/`maproot_group` silently breaks the `nfs-csi`
dynamic StorageClass specifically.** Confirmed live: `General/longhorn` (the
export backing `infrastructure/storage/csi-driver-nfs`'s `nfs-csi`
StorageClass — used for dynamic provisioning, not a static PV like every
export elsewhere in this doc) had somehow ended up with both fields blank.
Any PVC using `storageClassName: nfs-csi` got stuck `Pending` forever with
`failed to make subdirectory: ... permission denied` — NFS root-squash was
mapping the CSI provisioner's root-owned `mkdir` to `nobody`, which has no
write access to the dataset. This went unnoticed for 4+ days on a real
deploy (Gitea's `gitea-shared-storage` PVC) because nothing else alerts on
a stuck PVC. If a `nfs-csi`-backed PVC won't bind, check this export's
`maproot_user`/`maproot_group` first via `GET /api/v2.0/sharing/nfs`
before assuming the problem is the PVC/StorageClass spec itself — and
after fixing the export, `kubectl rollout restart
deployment/csi-nfs-controller -n csi-driver-nfs` to force an immediate
retry rather than waiting out the provisioner's accumulated backoff.

### Scratch-pod pattern for inspecting/mounting an export

Useful both to sanity-check a new export and, more importantly, to reach
data TrueNAS's own broken app orchestration can't get you (see the
Postgres recovery section below):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nfs-scratch
  namespace: default
spec:
  restartPolicy: Never
  containers:
    - name: scratch
      image: busybox
      command: ["sh", "-c", "sleep 300"]
      volumeMounts:
        - name: data
          mountPath: /mnt/data
  volumes:
    - name: data
      nfs:
        server: 10.0.0.5
        path: /mnt/General/<app>/<dataset>
```

If the mounted data is owned by a non-root uid/gid (TrueNAS apps commonly
run as uid/gid 568, its `apps` user), the container needs a matching
`securityContext.runAsUser`/`runAsGroup` to read/write it — a root
container gets `Permission denied` against `drwxrwx---` data owned by
another uid, same as the bare-node mount failure above, but this time
it's a real ownership mismatch, not a client-tooling issue.

## Recovering data from a crashed TrueNAS app

TrueNAS's own container orchestration (`docker compose` under the hood,
driven by `POST /api/v2.0/app/start` etc.) can get stuck — a dependent
container marked "unhealthy" blocks the whole compose `up`, and the only
error surfaced through the job API is a generic
`Failed 'up' action for '<app>' app. Please check /var/log/app_lifecycle.log`.
That log is fetchable over the REST API even though there's no plain
`GET` log endpoint — wrap it in a `core.download` job:

```
curl -s -k -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"method":"filesystem.get","args":["/var/log/app_lifecycle.log"],"filename":"app_lifecycle.log","buffered":true}' \
  'https://10.0.0.5/api/v2.0/core/download'
# -> [<job id>, "/_download/<job id>?auth_token=..."]
curl -s -k 'https://10.0.0.5/_download/<job id>?auth_token=...'
```

Don't assume a stuck/crashed app means the *data* is bad — confirmed live
with Immich, whose `pgvecto` (Postgres) container had been `exited` for
about three weeks, but the underlying data files were completely intact.
The orchestration layer and the data are separate failure domains; check
the data before assuming a migration needs to start from zero.

To confirm/extract data from a crash-looping database container without
fighting TrueNAS's own broken `docker compose up`: NFS-export the
database's raw data directory (see above), then run the exact same image
tag TrueNAS was using (check `active_workloads.container_details[].image`
in the app's `GET /api/v2.0/app/id/<name>` response) as a scratch pod
pointed at the same `PGDATA` path directly — bypassing compose's health
dependency chain entirely:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pg-recover
  namespace: default
spec:
  restartPolicy: Never
  containers:
    - name: postgres
      image: <exact image:tag TrueNAS was running>
      env:
        - name: POSTGRES_PASSWORD
          value: recover
        - name: PGDATA
          value: /var/lib/postgresql/data/<pg major version>/docker   # check the real subpath first, see below
      volumeMounts:
        - name: dbdata
          mountPath: /var/lib/postgresql/data
      ports:
        - containerPort: 5432
  volumes:
    - name: dbdata
      nfs:
        server: 10.0.0.5
        path: /mnt/General/<app>/db
```

`PGDATA`'s exact subpath is app-specific — inspect the mounted volume
first (`kubectl exec ... -- find /mnt/data -maxdepth 3`) rather than
guessing; Immich's TrueNAS catalog app laid it out as
`<mount>/15/docker/` (Postgres major version as a path segment, to
support the app's own future in-place major-version upgrades), not a flat
`<mount>/`.

**The app's own catalog Postgres image may not create a `postgres`
superuser role at all.** TrueNAS's Immich app used a custom role (named
`immich`, matching its `DB_USERNAME`) as the actual superuser — connecting
as `-U postgres` failed with `role "postgres" does not exist`. If you
don't know the real role/database names, don't guess against
`pg_hba.conf`'s `trust`-authenticated local socket (any wrong role name
still gets rejected) — start the container in single-user mode instead,
which bypasses role auth entirely, and query `pg_authid`/`pg_database`
directly:

```
kubectl exec <pod> -- bash -c 'echo "select rolname from pg_authid;" | su postgres -c "postgres --single -D <PGDATA> template1"'
```

(needs to run as the image's actual `postgres` OS user via `su`, since
running the server binary as container root is refused outright.)

Once the role/database names are known, start the container normally and
`pg_dump -Fc` it out to a durable location — the k3s node's local disk
(`/root/<app>-migration/`), not inside the scratch pod, which disappears
once deleted:

```
kubectl exec <pod> -- pg_dump -U <role> -d <database> -Fc -f /tmp/<app>.dump
kubectl cp default/<pod>:/tmp/<app>.dump /root/<app>-migration/<app>.dump
```

## Getting the dump into the new in-cluster database

If the new database runs as a CloudNativePG `Cluster`
(`infrastructure/controllers/cnpg/`, added for exactly this purpose — see
`applications/immich/postgres-cluster.yaml`), its pod's root filesystem is
read-only; `kubectl cp` a dump there under its PGDATA PVC mount instead
(e.g. `/var/lib/postgresql/data/<app>.dump`), then `pg_restore` from
inside that same pod as the `postgres` superuser over the local socket —
no network hop, no password needed:

```
kubectl cp /root/<app>-migration/<app>.dump <ns>/<cluster>-1:/var/lib/postgresql/data/<app>.dump -c postgres
kubectl exec -n <ns> <cluster>-1 -c postgres -- pg_restore -U postgres -d <database> --no-owner --role=<app-owner-role> -j4 /var/lib/postgresql/data/<app>.dump
kubectl exec -n <ns> <cluster>-1 -c postgres -- rm -f /var/lib/postgresql/data/<app>.dump   # clean up afterward
```

A handful of `must be owner of extension <ext>` errors on `COMMENT ON
EXTENSION` statements are expected and harmless if extensions were
pre-created as the `postgres` superuser rather than the app's owner role
before the restore — they're comment-only, not data.

**If the target app version is newer than the dump's schema** (e.g.
jumping several major versions), and the app's own server container has
already booted once against the fresh empty database and auto-migrated
it to the *new* schema, don't restore the old dump on top of that — drop
and recreate the database first so the dump's original (older) schema
restores cleanly, then let the app's own migration runner bring it
forward on next boot, exactly like a normal in-place upgrade would:

```
kubectl exec -n <ns> <cluster>-1 -c postgres -- psql -U postgres -d postgres \
  -c "select pg_terminate_backend(pid) from pg_stat_activity where datname='<database>' and pid <> pg_backend_pid();"
kubectl exec -n <ns> <cluster>-1 -c postgres -- psql -U postgres -d postgres -c 'DROP DATABASE <database>;'
kubectl exec -n <ns> <cluster>-1 -c postgres -- psql -U postgres -d postgres -c 'CREATE DATABASE <database> OWNER <app-owner-role>;'
# re-create any extensions the bootstrap.initdb.postInitApplicationSQL normally handles, then pg_restore as above
kubectl rollout restart deploy/<app-server>   # so it reconnects against the restored data instead of the schema it just created
```

Check the target version's release notes for hard extension-migration
requirements before doing this — e.g. Immich v3 drops `pgvecto.rs`
support entirely, so the source TrueNAS database needs to already be on
`vectorchord` (or migrated to it) before this restore path works; check
`active_workloads.container_details[].image` for the Postgres image
TrueNAS was running (`...vectorchord...` vs `...pgvecto.rs...` in the
tag) to know which side of that migration the source data is on.

## Decommissioning the TrueNAS app

Once the in-cluster version is verified working (check actual data, not
just that pods are `Running` — restart the new deployment once after any
manual DB surgery so it reconnects cleanly, and confirm row counts or
equivalent match the source):

```
curl -s -k -X DELETE -H "Authorization: Bearer $KEY" 'https://10.0.0.5/api/v2.0/app/id/<name>'
```

A plain `DELETE` with no extra flags removes the app's containers and
network but leaves both ix-volumes and bind-mounted host paths untouched
— confirmed live, `General/<app>/uploads` and `General/<app>/db` both
survived an `immich` app deletion intact. Only pass
`force_remove_ix_volumes: true` if you actually want those wiped too
(not needed for a migration where you're keeping the data around, even
temporarily, as a rollback safety net).

## Talking to the TrueNAS API

REST API at `https://10.0.0.5/api/v2.0/`, key-authenticated
(`Authorization: Bearer <key>` header) — see
`infrastructure/storage/truenas-api-key-secret.yaml` for how the key
itself is stored (live Secret, `default` namespace, not committed). Full
schema is discoverable at `https://10.0.0.5/api/v2.0/openapi.json`
(~4MB; worth fetching once into a local file and `grep`ing/`jq`ing it
rather than guessing endpoint shapes) — e.g.
`GET /api/v2.0/app/id/<name>` for full app state and container details,
`POST /api/v2.0/app/stop` / `/app/start` / `/app/redeploy` (job-based,
poll `GET /api/v2.0/core/get_jobs?id=<id>` for completion) for lifecycle
actions. These lifecycle endpoints take the app name as a **bare JSON
string body** (`-d '"radarr"'`), not `{"app_name": "radarr"}` — the
latter fails with `[EINVAL] app_name: Input should be a valid string`;
check `components.schemas.app_stop` (etc.) in the openapi doc if a
request body shape isn't obvious from the endpoint name alone, rather
than guessing. `get_jobs?id=<id>` also only accepts one `id` per call —
`?id=<a>&id=<b>` silently returns nothing, so poll each job separately.
There is deliberately no plain container-log REST endpoint —
logs are websocket-only in this API version; use the `core.download`
job-wrapper trick above for any log file instead of trying to find a
websocket client for a one-off read.

TrueNAS itself has SSH disabled (confirmed live: `Connection refused` on
`:22`) — the REST API plus scratch pods reaching it over NFS is the only
way in from the cluster side.

## DNS and routing for the new app

Once the app has an `HTTPRoute` in the cluster, three separate things
need a matching hostname entry — see `applications/immich/httproute.yaml`
and its follow-up commit for the concrete example:

1. **Public DNS**: automatic — `external-dns`
   (`infrastructure/networking/external-dns/`) watches `HTTPRoute`
   resources and creates the Cloudflare record on its own once the
   `HTTPRoute` syncs. Nothing to do here.
2. **In-cluster DNS** (`infrastructure/networking/coredns-custom/`): add
   the hostname to its `hosts` block, pointing at the same Gateway VIP
   the `HTTPRoute`'s `parentRef` attaches to (`192.168.1.240` for
   `gateway-internal`, `192.168.1.241` for `gateway-headscale`). Without
   this, in-cluster clients resolving the public hostname hit the
   hairpin-NAT issue (see CLAUDE.md's networking-quirks section).
3. **LAN DNS** (`infrastructure/dns-technitium/`, hand-applied — not
   GitOps-managed, Technitium runs outside the cluster): same record,
   added via its REST API
   (`GET /api/zones/records/add?token=<token>&domain=<host>&zone=jvos.dev&type=A&ipAddress=<vip>&ttl=300`)
   using the `technitium-api-token` Secret
   (`infrastructure/dns-technitium/technitium-api-token-secret.yaml` for
   the reference copy / live-Secret convention). Update that directory's
   README record table to match afterward — it's the only place this
   list is tracked.

## Inter-app config: other apps may still reference the old address/port

If the migrated app is one that other apps talk to directly (not through
a browser/HTTPRoute — e.g. Prowlarr's Settings → Apps connections to
Sonarr/Radarr, or Sonarr/Radarr's own download-client entries for
qbittorrent), migrating just that one app isn't enough — every *other*
app's stored connection to it still points at whatever
host:port it used to be reachable at on TrueNAS, which usually differs
from its new in-cluster Service. Confirmed live: Prowlarr kept trying
`radarr:30025` (TrueNAS's custom host-mapped port for Radarr) after
Radarr moved into the cluster, failing with "Host is unreachable",
because the in-cluster `radarr` Service actually listens on `7878` (the
image's default port — this repo doesn't generally preserve TrueNAS's
custom port numbers when migrating an app, see
`applications/arr-stack/sonarr-radarr-bazarr.yaml`'s port choices).

This is invisible from the newly-migrated app's own side — it comes up
fine, its own HTTPRoute/DNS work — the failure only shows up when you
exercise the *other* app's "Test connection" against it. After migrating
any app that others talk to directly, check every other in-cluster app's
own settings UI for a stale reference to it (old TrueNAS
hostname/IP/port) and update to `<service-name>:<in-cluster-port>`
instead — this is a manual per-app UI/config fix, not something the
cluster migration itself can carry over, since that config lives inside
each app's own database, not in this repo.
