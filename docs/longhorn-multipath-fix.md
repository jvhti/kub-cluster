# Longhorn volumes stuck "device busy" — multipathd claiming iSCSI LUNs

Found and fixed 2026-08-29, during an extended outage that started as
`fotos.jvos.dev` (Immich) returning `upstream connect error` and turned out
to be a cluster-wide storage problem hitting far more than Immich.

## Symptom

A pod with a Longhorn-backed PVC gets stuck `ContainerCreating` or
`Init:0/1` indefinitely. `kubectl describe pod` shows repeating
`FailedMount` events like:

```
MountVolume.MountDevice failed for volume "pvc-..." : rpc error: code =
Internal desc = mount failed: exit status 32
Output: mount: /var/lib/kubelet/plugins/kubernetes.io/csi/driver.longhorn.io/.../globalmount:
/dev/longhorn/pvc-... already mounted or mount point busy.
```

or, if kubelet is trying to format a brand-new volume:

```
format of disk "/dev/longhorn/pvc-..." failed: ... errcode:(exit status 1)
output:(mke2fs 1.47.0 (5-Feb-2023)
/dev/longhorn/pvc-... is apparently in use by the system; mke2fs forced anyway.
/dev/longhorn/pvc-...: Device or resource busy while setting up superblock
)
```

Confusingly, **Longhorn's own control plane reports the volume as
`attached healthy`** (`kubectl get volumes.longhorn.io -n longhorn-system`),
and `mount | grep <pvc>` / `/proc/mounts` on the node show nothing —
the block device genuinely isn't mounted anywhere. This makes it look
like a stale/leaked mount, but it isn't one.

This is **silent and cluster-wide**: it can hit a completely fresh PVC
(ruling out per-volume corruption) and has been observed on both
`kub-ctrl-1` and `kub-node-1`. It also **survives a full node reboot** —
two reboots of `kub-node-1` during the 2026-08-29 incident didn't fix it,
because the thing causing it re-activates automatically at every boot.

## Root cause

`multipathd` is running on the node (Ubuntu/Debian default, nothing
disables it) and is **incorrectly claiming Longhorn's iSCSI-backed block
devices as multipath devices**, even though nothing in this cluster
actually has multiple paths — every Longhorn LUN is single-path. You can
see this directly:

```
$ multipath -ll
mpathc (360000000000000000e00000000070001) dm-0 IET,VIRTUAL-DISK
size=10G features='0' hwhandler='0' wp=rw
`-+- policy='service-time 0' prio=1 status=active
  `- 16:0:0:1 sdo 8:224 active ready running
```

and in `lsblk`, compare a working volume to a claimed one — same
type/size, but the claimed one has no mountpoint and a `mpath*` child:

```
sdn        20G disk  /var/lib/kubelet/pods/.../pvc-a41ce058.../mount   # fine
sdo        10G disk                                                   # claimed
`-mpathc   10G mpath
```

`multipathd` races Longhorn's own iSCSI attach for the device. Longhorn's
manager sees its own attach succeed (so it reports `healthy`), but when
kubelet then tries to mount or `mke2fs` the raw device node, the kernel
already considers it in use by the `dm-*` multipath wrapper — hence
`Device or resource busy` / `already mounted or mount point busy`. Two
different subsystems both think they own the block device.

Symptom cascades to **every pod with a Longhorn PVC scheduled on the
affected node** — during the incident this took down Gitea's Postgres HA
cluster, Authelia, Homarr, Grafana, Paperless, Wireguard, memos, radarr,
degoog, and Immich's postgres/redis, all at once, on top of an unrelated
node-load problem that made it initially look like the whole thing was one
issue (it wasn't — see the ArgoCD zombie-process note in git history
around this date if debugging a similar node meltdown).

## Fix

Blacklist the offending device (`IET`/`VIRTUAL-DISK` — the SCSI target
vendor/product string every Longhorn iSCSI LUN reports) in
`/etc/multipath.conf`, then restart `multipathd`:

```
defaults {
    user_friendly_names yes
}
blacklist {
    device {
        vendor "IET"
        product "VIRTUAL-DISK"
    }
}
```

```
systemctl restart multipathd
multipath -ll   # should now print nothing
```

Do **not** run `multipath -F` (flush) first if any affected volume is
actively mid-mount-attempt — it hangs indefinitely waiting on the in-use
map. Just restarting `multipathd` with the new blacklist in place is
enough; the stray `dm-*` maps disappear on their own once nothing
references them anymore. Confirmed: within a couple of minutes of the
restart, every stuck pod's next kubelet mount retry succeeds on its own —
no pod restarts needed.

Applied and confirmed working on `kub-ctrl-1` and `kub-node-1` (both
amd64) on 2026-08-29. **Not yet confirmed needed on `pi1` (arm64) or
`overkill`** — apply there too on a rebuild or if the same symptom shows
up, to be safe, but hasn't been observed there.

**This isn't tracked anywhere in git-managed node bootstrap** (there's no
cloud-init/Ansible/etc. for these nodes — see the k3s `config.yaml` sysctl
note elsewhere in this repo's `CLAUDE.md` for the same caveat). If a node
gets rebuilt from scratch, this file has to be recreated manually.

## How to apply this without SSH

Per this repo's access notes, there's no direct SSH to the nodes. A
`kubectl debug node/<node>` pod works but can itself get stuck scheduling
if the node is under enough strain (it hit this during the same incident).
The pattern that worked reliably:

```bash
kubectl run mpfix --image=busybox --restart=Never --overrides='
{
  "spec": {
    "nodeName": "<node>",
    "hostPID": true,
    "containers": [{
      "name": "m", "image": "busybox", "command": ["sleep", "300"],
      "securityContext": {"privileged": true}
    }]
  }
}'

# write the config via nsenter + tee, piping local content over stdin:
kubectl exec -i mpfix -- nsenter -t 1 -m -p tee /etc/multipath.conf < multipath.conf

# restart multipathd in the host namespace:
kubectl exec mpfix -- nsenter -t 1 -m -p sh -c \
  'systemctl restart multipathd; sleep 2; multipath -ll'

kubectl delete pod mpfix --wait=false
```

## Leftover from this incident

`applications/immich/redis.yaml` currently carries a `nodeAffinity`
excluding `kub-node-1`, added mid-incident as a workaround before this was
root-caused. Safe to remove once the multipath fix has had a reboot or
two to prove durable — it's redundant now that the actual cause is fixed
on that node.
