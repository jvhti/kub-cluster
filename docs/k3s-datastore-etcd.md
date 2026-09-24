# K3s datastore: SQLite (kine) → embedded etcd

Converted **2026-09-23** after a full cluster collapse traced to the default
embedded SQLite (kine) datastore at `/var/lib/rancher/k3s/server/db/state.db`.

## Symptom class

Under write churn (CNPG controllers, app workloads) kine's WAL balloons
(~354MB) and never checkpoints, big kine LISTs fall back to 20-30s sequential
scans (`Slow SQL ... duration=23s` in the k3s journal), and that snowballs
into:

- apiserver `LIST` timeouts
- `kub-ctrl-1`'s `k3s-server` pinned at ~200-350% CPU (host looked pegged)
- worker agents wedged in a retry loop on the supervisor `/v1-k3s/config`
  handshake
- floating `healthz` latency of 2.5-4s, `kubectl get pods -A`
  (294 pods) failing with >100s timeouts

## Why the stopgap wasn't enough

`PRAGMA wal_checkpoint(TRUNCATE)` + `REINDEX` + `VACUUM` (run with k3s stopped)
brought `state.db` from ~540MB + 354MB WAL down to a clean 385MB file, and the
apiserver recovered immediately — but under the next churn window the WAL
regrew to 354MB within the hour. The kine revision table (max id 25M+) is the
structural problem; write-heavy workloads keep re-creating it.

## The fix

Official k3s feature: "convert an existing SQLite single-node cluster to etcd
by simply restarting the server with `--cluster-init`"
(https://docs.k3s.io/datastore/ha-embedded#existing-single-node-clusters).

Steps taken (k3s v1.36.3+k3s1):

1. `systemctl stop k3s` (the k3s-server unit is `k3s` on this node; agents use
   `k3s-agent`).
2. Back up the datastore while stopped:
   `tar -C /var/lib/rancher/k3s/server -czf db.sqlite-backup-<ts>.tgz db`
3. While stopped, compact what will be migrated (optional but recommended):
   `sqlite3 state.db "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA quick_check; REINDEX; VACUUM; PRAGMA optimize;"` → quick_check `ok`.
4. Add `cluster-init: true` to `/etc/rancher/k3s/config.yaml` (see
   `CLAUDE.md` — the flag must survive, or a rebuild silently reverts to
   SQLite).
5. `systemctl start k3s` — k3s detects the SQLite datastore and migrates it to
   embedded etcd automatically.

## Verify

- `/var/lib/rancher/k3s/server/db/` contains an `etcd/` dir plus the renamed
  `state.db.migrated` (the old SQLite, renamed post-conversion).
- Node gains the `etcd` role and `kubectl get nodes` shows all servers Ready.
- Measured before/after on the same hosts:

  | metric | SQLite (collapsed) | etcd |
  |---|---|---|
  | `healthz`/`readyz` | 2.5-4s | 0.07-0.2s |
  | `kubectl get pods -A` (294 pods) | >100s / timeout | ~1s |

## Operational notes

- **Snapshots**: embedded etcd auto-snapshots on a 12h cron (retention 5,
  default `0 */12 * * *`) to `/var/lib/rancher/k3s/server/db/snapshots`;
  on-demand via `k3s etcd-snapshot save` (this also exercises the full etcd
  write path — a quick health probe). List/retention:
  `k3s etcd-snapshot ls`.
- **Node rebuild recovery** is the etcd path now, NOT a sqlite file copy:
  `k3s server --cluster-reset --cluster-reset-restore-path=<snapshot>` (see
  https://docs.k3s.io/datastore/backup-restore).
- **`cluster-init: true` is REQUIRED** in kub-ctrl-1's
  `/etc/rancher/k3s/config.yaml` (`K3S_CLUSTER_INIT`). Dropping it on a
  rebuild silently reverts to SQLite. The first
  `config.yaml` bullet in `CLAUDE.md` predates this and shows the old 3-line
  file; the ctrl file is now 5 lines (kubelet-arg + cluster-init).
- **Rollback safety artifacts** still on disk until confident:
  `state.db.migrated`, `state.db-shm`, `state.db-wal`,
  `db.sqlite-backup-*.tgz`, `state.db.saved-*`. Safe to delete once the etcd
  cluster has run clean for a while and snapshots are good.
- If the API ever looks slow again under load, check etcd health first
  (`k3s etcd-snapshot save`, `kubectl get --raw /readyz`), and inspect
  `journalctl -u k3s` for kine-style `Slow SQL` lines (should be gone; etcd
  does point/prefix reads, not grow-a-huge-table scans).
- Only kub-ctrl-1 runs the server; etcd is a single-member cluster. Same
  availability as before (SQLite was single-node too), but large LISTs and
  write churn no longer degrade to sequential scans.