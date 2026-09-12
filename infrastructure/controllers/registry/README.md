# Docker Hub pull-through cache

`registry:2` running in-cluster, caching Docker Hub images so nodes don't
re-hit (and get rate-limited by) Docker Hub on every pull. The manifests here
(`pvc.yaml`, `registry.yaml`) are ArgoCD-managed. **Wiring the nodes up is
NOT** — k3s reads its registry mirror config from a per-node file that ArgoCD
can't manage (same category as the `/etc/rancher/k3s/config.yaml`
`kubelet-arg` note in the repo's CLAUDE.md).

## How it works

- The `registry` Deployment is a `registry:2` **pull-through cache**:
  `REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io`, so every pull it
  receives is fetched from Docker Hub on a miss and cached on the
  `registry-data` PVC on a hit.
- The Service exposes it two ways (see `registry.yaml`):
  - **ClusterIP `10.43.255.254:5000`** (pinned, stable) — preferred.
  - **NodePort `30500`** (reachable at `localhost:30500` on every node) —
    fallback.
- Each node's k3s is told, via `/etc/rancher/k3s/registries.yaml`, to route
  `docker.io` pulls through that address. containerd tries the mirror first
  and **falls back to Docker Hub directly if the mirror is unreachable** —
  this also sidesteps the chicken-and-egg (pulling `registry:2` itself before
  the cache is up).

## One-time imperative setup (per node)

There is **no direct SSH to the nodes** — run this via a `kubectl debug
node/<node>` privileged pod (host root is mounted at `/host`), the same
pattern as the CLAUDE.md node-debugging note. Do it on **all four** nodes:
`kub-ctrl-1`, `kub-node-1`, `overkill`, `pi1`.

First confirm which address the node can actually reach for image pulls
(prefer the ClusterIP; only use the NodePort if the ClusterIP test fails):

```
kubectl debug node/kub-node-1 --image=curlimages/curl -- sh -c \
  'curl -s -o /dev/null -w "clusterIP=%{http_code}\n" http://10.43.255.254:5000/v2/ ; \
   curl -s -o /dev/null -w "nodeport=%{http_code}\n" http://localhost:30500/v2/'
```

Then write the mirror config and restart k3s (the file is read at k3s
startup — a restart is required for it to take effect):

```
# pick the endpoint that returned 200 above:
#   clusterIP reachable  ->  "http://10.43.255.254:5000"
#   nodeport only        ->  "http://localhost:30500"
ENDPOINT="http://10.43.255.254:5000"

kubectl debug node/kub-node-1 --image=busybox -- sh -c "
  mkdir -p /host/etc/rancher/k3s
  printf 'mirrors:\n  \"docker.io\":\n    endpoint:\n      - \"$ENDPOINT\"\n' > /host/etc/rancher/k3s/registries.yaml
  chroot /host /usr/bin/systemctl restart k3s
"
```

> **`kub-ctrl-1` is the control plane** — restart it LAST, and be ready to
> wait ~20-40s while etcd/apiserver come back up. The other three are plain
> agents (`k3s-agent` on `kub-node-1`/`overkill`/`pi1`, but `systemctl
> restart k3s` works on all of them since k3s-agent is the service unit there).

## Verify

```
# pull a small image and watch it come from the cache (second pull is fast):
kubectl debug node/kub-node-1 --image=busybox --image-pull-policy=Always -- sh -c 'sleep 5'
# in the registry pod, you'll see the proxied GETs to registry-1.docker.io on
# the first pull only; repeat the pull and the cache serves it locally.
kubectl logs -n registry deploy/registry --tail=20
```

## Operations

- **Cache size**: `registry-data` is 30Gi (longhorn). If it fills up, either
  grow it (longhorn online expansion) or clear it:
  `kubectl delete pvc -n registry registry-data` (the PVC + cache rebuild on
  demand).
- **Registry image / config changes**: edit the manifests here, commit + push
  (GitOps). The per-node `registries.yaml` only needs re-doing if you change
  the registry's address (ClusterIP/NodePort).
