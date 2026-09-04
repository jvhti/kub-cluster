# Immich crash-looping on `CONNECT_TIMEOUT` — stale Cilium LB backend on kub-node-1

Found and fixed 2026-09-04. Started as `immich-server` in
CrashLoopBackOff (~335 restarts) dying at boot with
`write CONNECT_TIMEOUT immich-postgres-rw:5432`, turned out to be a
per-node Cilium datapath desync on `kub-node-1` affecting ~15 services,
not Immich or Postgres at all.

## Symptom

- `immich-server` (only replica, scheduled on `kub-node-1`) crash-loops.
  Last logs before the crash are just:
  ```
  Initializing Immich v3.1.0
  Detected CPU Cores: 8
  Error: write CONNECT_TIMEOUT immich-postgres-rw:5432
  ```
  The whole crash is <1s after boot — the very first Postgres connection
  from the pod times out.
- Everything about the database looks healthy:
  - CNPG cluster `immich-postgres` reports `Cluster in healthy state`,
    1/1, `pg_isready` inside `immich-postgres-1` says "accepting
    connections", postgres logs show normal checkpoints.
  - The EndpointSlice for `immich-postgres-rw` is correct
    (`10.42.0.46:5432`, ready+serving).
  - From a test pod **on `kub-node-1`**, connecting straight to the pod
    IP (`10.42.0.46:5432`) takes **0.07s**.
  - From a test pod **on `kub-ctrl-1`**, connecting via the ClusterIP
    (`immich-postgres-rw`, `10.43.142.36`) takes **0.1s**.
  - Other ClusterIP services from `kub-node-1` (memos-postgres-rw,
    coredns) respond instantly.
- The only broken combination: **new connections from `kub-node-1` to
  this one ClusterIP**. And even that is intermittent — a rapid
  8-attempt loop gives e.g. `F F F O O F F O` (each F is a full timeout,
  each O is <1s). That bursty, non-cold-start pattern is the tell:
  it's a hash, not a state machine.

## Root cause

Cilium's BPF service-LB map **on `kub-node-1` only** contained stale
revNAT entries for the service, pointing at dead pod IPs alongside the
live one. `cilium bpf lb list` on the node showed three entries for the
same frontend:

```
10.43.142.36:5432/TCP (1)     10.42.0.46:5432/TCP (112) (1)      # live postgres
10.43.142.36:5432/TCP (2)     10.42.0.194:5432/TCP (112) (2)     # DEAD — no pod has this IP
10.43.142.36:5432/TCP (0)     0.0.0.0:0 (112) (0) [ClusterIP, non-routable]   # normal placeholder
```

The cluster uses `loadBalancer.algorithm: maglev`
(`infrastructure/networking/cilium/values.yaml`), so every **new**
connection's 5-tuple is hashed to pick a backend. With one dead backend
in the table, roughly half of all new 5-tuples from `kub-node-1` were
DNAT'd to `10.42.0.194:5432` — an IP assigned to no pod — so the SYN was
routed into the void and the client sat on TCP timeout. Existing
established flows keep their conntrack entries and were unaffected, which
is why only connection-heavy-at-boot or reconnecting workloads noticed.

`immich-server` is the perfect victim: it opens all its pool connections
at startup (fresh 5-tuples, fresh hashes, every restart) and a single
failed first query kills the process. Being the only consumer of that
service scheduled on the affected node, it crash-looped 335 times while
the same service worked fine from everywhere else.

The desync traces to the cluster-wide restart event ~39h before the
immich debugging started (`cilium-lhnl8` on kub-node-1 had 8 restarts
that day; `cilium-operator` 14; `hubble-relay` 107). The agent came back
with duplicate/stale per-service state. **The other three nodes
(kub-ctrl-1, pi1, overkill) were clean** — same service, single live
backend, no stale entries.

## Why the obvious checks all passed

- `cilium service list` on kub-node-1 showed the service with exactly one
  **correct** backend (`=> 10.42.0.46:5432 (active)`). That's the agent's
  API-level view; the stale entry only existed in the **BPF map**
  (`cilium bpf lb list`). If you trust `service list` here, you'll miss
  it.
- Per-node service IDs differ across nodes (coredns is ID 6/57/63/… on
  the four nodes; this service was 31/112/108/128). That divergence is
  normal in this cluster and is **not** the cause — other services with
  the same divergence work fine.
- Kernel conntrack (`/proc/net/nf_conntrack`) had no stale entries; the
  stale state is in Cilium's BPF maps, not the kernel's.

## Diagnosis recipe (what actually found it)

All from the bastion; `<CIDR-pod>` = a throwaway pod pinned to the
suspect node via `nodeSelector: kubernetes.io/hostname`.

1. **Split the path.** Test pod on `kub-node-1` with the real app
   credentials (image: the CNPG one, it has `psql`):
   - `psql ...@<pod-IP>:5432` → fast? proves node-to-node pod path OK
   - `psql ...@<svc>:5432` → full timeout? isolates to the ClusterIP/LB path
   - same via a different service from the same pod → is it service-specific
2. **`cilium bpf lb list | grep <clusterIP>`** in the suspect node's
   cilium pod (`kubectl exec -n kube-system <cilium-pod> --`). More than
   one real-backend line for the same frontend = stale entry.
3. **Prove the DNAT target of a failing flow**: trigger one failing
   connection, then within ~20s run
   `cilium bpf ct list global | grep <client-pod-IP>` on the client node —
   the `TCP OUT` line shows where the SYN was actually sent
   (`-> 10.42.0.194:5432`, `Packets=0`).
4. **Audit the whole node**:
   ```bash
   kubectl exec -n kube-system <cilium-pod> -- cilium bpf lb list > lb.txt
   kubectl get pods -A -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' | sort -u > live.txt
   awk '{for(i=1;i<=NF;i++) if($i ~ /^10\.42\./) print $i}' lb.txt | awk -F: '{print $1}' | sort -u > backends.txt
   comm -23 backends.txt live.txt   # backend IPs in the map that no live pod owns
   ```
   On kub-node-1 this found **10 dead IPs across ~15 services** (immich +
   3 other CNPG postgres, 5 old frigate pods, the monitoring stack,
   …) — everything with a stale entry had a ~coin-flip failure rate for
   new connections from that node. memos-postgres had a stale entry too;
   it only "worked" in the initial test because that particular 5-tuple
   hashed to the live backend.
5. Repeat 4 on every node — here only kub-node-1 was affected.

## Fix

Restart the desynced agent. The DaemonSet recreates it and the agent
rebuilds all BPF service state from the k8s API on startup, dropping
every stale entry at once:

```bash
kubectl delete pod -n kube-system cilium-lhnl8   # the agent on kub-node-1
```

Blast radius: pods on the node keep their IPs (Cilium IPAM is stable),
but expect ~10–60s of dropped/retrying traffic to/from that node while
the new agent re-initializes BPF. `kub-node-1` hosts roughly half the
workload, so do it at a quiet time.

Verified 2026-09-04: post-restart `cilium bpf lb list` for the service
shows only the live backend, the full-node audit returns zero stale
IPs, 10/10 `psql` attempts from `kub-node-1` succeed in <1s, and
`immich-server` booted cleanly on its next crash-loop cycle and stayed
Ready.

## Follow-ups

- If this recurs after a from-scratch agent restart, treat it as a
  Cilium bug worth escalating — the cluster is on `v1.19.1`; an upgrade
  is the durable mitigation.
- The per-node stale-state class means **any** mass agent/operator
  restart (node reboots, OOMs, rolling updates) is a risk window. If a
  node goes through a Cilium restart and apps on it start flaking with
  connection timeouts to *healthy* backends, run the audit from step 4
  before touching the apps.
