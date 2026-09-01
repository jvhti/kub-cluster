# Local LLM inference — llama.cpp on two homelab boxes

Reference-only, like `docs/dmz-forwarder/`: **neither host is part of the k3s
cluster or managed by ArgoCD.** Both are separate boxes on the LAN running
`llama.cpp` directly via systemd. This doc exists so the setup, the tuning
rationale, and the gotchas aren't lost — nothing here is git-managed on
either host.

## Hosts

| | `192.168.1.202` (Proxmox, LXC 139) | `192.168.1.211` (`overkill`) |
|---|---|---|
| GPU | RTX 2060 Mobile, 6GB VRAM | RTX 4090, 24GB VRAM |
| OS | Debian 13 (trixie) LXC on Proxmox 9.2.10 | Arch Linux, kernel 6.12 LTS |
| Driver | NVIDIA 595.99.02 (host) + matching userspace libs (container) | NVIDIA 610.43.03 |
| CUDA toolkit | 13.3 (`/usr/local/cuda-13.3`) | 13.3 (`/opt/cuda`) |
| llama.cpp | built from source, CUDA (`sm_75`) | built from source, CUDA (`sm_89`) |
| Serving mode | router mode, 2 models, swap on demand | router mode, 2 models, swap on demand |
| Port | `8080` | `8090` |
| Systemd unit | `llama-server.service` (root, in an unprivileged LXC) | `llama-server.service` (user `jvhti`) |

Access: Proxmox host via `ssh root@192.168.1.202`, then `pct exec 139 -- ...`
for anything inside the container. `overkill` via `ssh jvhti@192.168.1.211`
directly. **`overkill` requires an interactive sudo password for anything
touching `/etc/systemd/system/*` or `systemctl start/restart`** — no
passwordless sudo or askpass helper configured there, so those steps can't
be scripted through a non-interactive SSH session; give the user the exact
commands to run themselves instead of trying `ssh -t` (doesn't get a real
TTY through typical automation) or guessing the password.

---

## Proxmox box (`192.168.1.202`, LXC 139) — RTX 2060, 6GB VRAM

### Why the host needed fixing first

The NVIDIA driver had been installed manually (`.run` installer,
2025-08-23) with no dkms, and the Proxmox kernel had moved through 6
versions since then with the module never rebuilt — `modprobe nvidia`
failed outright (`Module nvidia not found`). Tried the in-repo path first
(Debian's packaged `nvidia-open-kernel-dkms`, driver 550.163.01) — **too
old for this kernel's mm/VMA API** (`__vm_flags`, `VMA_LOCK_OFFSET`,
`pci_resize_resource` signature all changed). Ended up installing NVIDIA's
latest upstream `.run` installer (**595.99.02**) with `--dkms`, which
builds cleanly and auto-rebuilds on future kernel bumps. The full
`nvidia-driver` Debian meta-package was tried and rejected — installing it
would have **removed `proxmox-ve` itself** (pulls in a full X11/desktop
stack that conflicts with Proxmox's own kernel/firmware packages); the fix
was installing only the minimal pieces (`nvidia-open-kernel-dkms`,
`libnvidia-cfg1`, `nvidia-smi`, firmware packages) — verify with `apt-get
install -s` before ever installing `nvidia-driver` on a Proxmox host.

Also added a **16GB swapfile** (`/swapfile`, in `/etc/fstab`) on the
Proxmox host — it's genuinely RAM-overcommitted (two 16GB k3s VMs,
`kubernetes-control-plane-1`/`kubernetes-node-1`, ids 134/135, unrelated to
this repo's cluster, plus ~20 other guests). The host OOM-killer hit one of
those VMs once during this setup, unprompted. The swapfile is a stopgap,
not a fix for the underlying overcommit — worth knowing if guests on that
box start acting up.

### LXC config

Container 139, unprivileged, Debian 13, DHCP (`192.168.1.18` currently).
GPU passthrough via `/etc/pve/lxc/139.conf`:

```
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.cgroup2.devices.allow: c 503:* rwm
lxc.cgroup2.devices.allow: c 506:* rwm
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-caps dev/nvidia-caps none bind,optional,create=dir
```

The device major numbers (`195`, `503`, `506`) came from `ls -la
/dev/nvidia*` on the **host** — they're not guaranteed stable across a host
reboot. If GPU passthrough breaks after rebooting the Proxmox host, re-check
those majors first.

Inside the container, only the NVIDIA **userspace libraries** are
installed (same `.run` file as the host, `--no-kernel-module`) — the kernel
module itself only exists on the host and is shared via the passed-through
device nodes. Installing the kernel module inside the container too would
be wrong (it doesn't own the actual hardware).

CUDA 13.3 toolkit is installed **inside the container** (needed to build
llama.cpp there) via NVIDIA's own runfile — Debian's `cuda-keyring` apt repo
is SHA1-signed and rejected outright by trixie's stricter policy, so that
path doesn't work here.

### Serving setup: router mode, two models

VRAM is tight enough (6GB) that the two models don't fit simultaneously, so
`llama-server`'s built-in **router mode** handles on-demand load/unload
instead of running two separate processes:

```ini
# /root/models/preset.ini
[*]
n-gpu-layers = 99
cache-type-k = q8_0
cache-type-v = q8_0
parallel     = 1
reasoning    = off
mmap         = 1

[qwen3-8b]
model    = /root/models/Qwen3-8B-Q4_K_M.gguf
ctx-size = 12288
ubatch-size = 128

[qwen3.5-4b]
model    = /root/models/Qwen3.5-4B-Q4_K_M.gguf
ctx-size = 98304
```

```ini
# /etc/systemd/system/llama-server.service (ExecStart)
/root/llama.cpp/build/bin/llama-server \
    --models-preset /root/models/preset.ini \
    --models-max 1 \
    --host 0.0.0.0 --port 8080
```

`--models-max 1` forces the router to unload whichever model is loaded
before loading the one a new request asks for (`"model": "qwen3-8b"` or
`"model": "qwen3.5-4b"` in the request body — both show up in `GET
/v1/models`). Confirmed working end-to-end: requesting one model unloads
the other and VRAM usage changes accordingly. First request after a swap
pays a few-second reload cost.

**Why two different models instead of one:**
- `qwen3-8b` (Qwen3-8B, Q4_K_M) — stronger general model, but only fits
  ~12K context in 6GB VRAM.
- `qwen3.5-4b` (Qwen3.5-4B, Q4_K_M) — smaller model, but its hybrid
  Gated-DeltaNet + Attention architecture (mostly linear-attention layers,
  full attention only every 4th block) makes KV cache dramatically cheaper
  per token. Fits **98304 (96K) context** in the same 6GB, vs. 12K for the
  8B model. Tested up to 131072 (5.6GB/6.1GB used, viable but thin margin)
  and the model's native 262144 (doesn't fit — OOMs on KV cache alloc).
  96K was chosen as the safe production value (4.9GB used, ~1.2GB
  headroom).
- Use `qwen3-8b` for general quality when the conversation is short; switch
  to `qwen3.5-4b` for anything needing long context (documents, long chat
  history).

### Tuning notes (RTX 2060 / Turing, `sm_75`)

Benchmarked with `llama-bench`, not guessed:

- **`--flash-attn on` is a regression here** — `auto` (which picks *not* to
  use flash-attn on this card) beat forcing `-fa on` on both pp and tg
  (1153 vs 903 t/s pp, 43.4 vs 36.9 t/s tg for Qwen3-8B). Turing's
  flash-attn CUDA kernels in llama.cpp aren't as optimized as later
  architectures — leave `-fa` unset/`auto`, don't force it on.
- **Smaller `-ub` wins** — swept 128/256/512/1024; 128 was consistently
  fastest (~35.5 t/s tg vs ~22-28 for larger values), reproduced across
  repeated runs. Counterintuitive vs. usual GPU advice, but consistent on
  this VRAM-constrained card.
- **q8_0 KV cache quantization roughly halves KV memory** for a given
  context size with no measurable quality complaint in testing — this is
  what makes 96K/12K context viable at all on 6GB. Don't skip it here (it's
  a bigger win than on the 4090, where VRAM headroom is ample either way).

### Qwen3 model family: thinking mode

Qwen3/Qwen3.5 default to **reasoning ("thinking") mode** — burns a large
chunk of `max_tokens` on visible reasoning text before the real answer
(`message.reasoning_content` in the API response) unless disabled. Open
WebUI's own "disable thinking" toggle **did not reliably reach the model**
in testing — the request-side `enable_thinking:false` field wasn't always
being set. Fixed it **server-side, permanently**, via `--reasoning off` in
the preset (`[*]` section, applies to both models) — this forces
non-thinking mode regardless of what any client sends, verified with a bare
request (no client-side override) returning a direct answer with
`reasoning_content: null`.

### Open WebUI context-size gotcha

Open WebUI (running separately, in the k3s cluster —
`applications/openwebui/`, not this repo's cluster's business but worth
noting since it's the client hitting these servers) sends a **surprisingly
large baseline prompt** — logs showed ~6093-6094 tokens for a bare "hello",
consistent across multiple messages (not growing with conversation length,
so likely a fixed system prompt / tool schema rather than accumulating
history — not fully root-caused, just worked around). This is why the
original `-c 4096` on the 8B model immediately errored
(`request (6094 tokens) exceeds the available context size`). Current
`-c 12288`/`98304` values account for this overhead; if Open WebUI's
baseline prompt size changes, the effective usable context for actual
conversation will shift accordingly.

---

## `overkill` (`192.168.1.211`) — RTX 4090, 24GB VRAM

Already had a working, well-tuned setup before this round of work (driver,
CUDA toolkit, llama.cpp build all pre-existing) — this pass was rebuild +
re-benchmark + apply idle-sleep, not a from-scratch build like the Proxmox
box.

### Models: router mode, two models

Same rationale as the Proxmox box, different cause — the 27B model alone
already uses ~22.7GB of the 24GB card at full 131072 context, so there's no
room to also keep a second model resident. Converted from a single always-on
process to router mode once a second model was added.

- **`qwen3.8-27b`** — `Qwen3.8-27B-Q4_K_M.gguf`
  (`/home/jvhti/Models/`), same Qwen3.5-family hybrid Gated-DeltaNet
  architecture as the 4B model on the Proxmox box, at 27B scale. Has a
  multi-token-prediction (MTP) head baked in as an extra model layer, used
  for speculative decoding (see below).
- A second, smaller model registered alongside it (HF-cache layout under
  `/home/jvhti/Models/models--...`, resolved via its `snapshots/<hash>/*.gguf`
  symlink). File size initially suggested a ~12-14B model, but
  `gguf_dump.py` showed it's actually **`general.architecture = gemma2`,
  9.24B params, native `context_length = 8192`** — a Gemma-2-9B based
  model, confirmed by its own self-identification in a test response
  ("Hello, my name is Gemma"). Context is capped at exactly 8192 in the
  preset — the model wasn't trained for anything longer, so there's no
  reason to request more (and it would degrade quality, not help).

### CUDA toolchain location

`nvcc` is **not on PATH** in a plain non-interactive SSH session on this
host — it lives at `/opt/cuda/bin/nvcc` (CUDA 13.3), with an old backup at
`/opt/cuda-12.9-backup/`. Any rebuild needs `PATH=/opt/cuda/bin:$PATH` and
`CUDAToolkit_ROOT=/opt/cuda` passed to `cmake`, or configure fails with
`Could not find nvcc`.

### Current preset (`/home/jvhti/Models/preset.ini`)

```ini
[*]
n-gpu-layers = 999
flash-attn   = auto
jinja        = 1

[qwen3.8-27b]
model         = /home/jvhti/Models/Qwen3.8-27B-Q4_K_M.gguf
ctx-size      = 131072
cache-type-k  = q4_0
cache-type-v  = q4_0
batch-size    = 2048
ubatch-size   = 512
cache-prompt  = 1
cache-ram     = 16384
spec-type     = draft-mtp
chat-template-kwargs = {"reasoning_effort": "medium"}

[gemma2-9b]
model         = /home/jvhti/Models/<...>/snapshots/<hash>/<file>.gguf
ctx-size      = 8192
cache-type-k  = f16
cache-type-v  = f16
batch-size    = 2048
ubatch-size   = 512
```

### Current `ExecStart`

```
/home/jvhti/llama.cpp/build/bin/llama-server \
    --host 0.0.0.0 --port 8090 \
    --models-preset /home/jvhti/Models/preset.ini \
    --models-max 1 \
    --sleep-idle-seconds 300
```

`--models-max 1` forces one model resident at a time, same as the Proxmox
box — request `"model": "qwen3.8-27b"` or `"model": "gemma2-9b"` in the
request body (both appear in `GET /v1/models`, actual `[section]` name is
whatever the preset uses). Note the Gemma2 model does **not** have
`--reasoning off` set (unlike the Proxmox preset) — it's not a
reasoning-capable model in the first place, so it wasn't needed; the 27B
model still shows `reasoning_content` in responses by design
(`chat-template-kwargs reasoning_effort: medium`), unchanged from before.

### Tuning notes (RTX 4090 / Ada Lovelace, `sm_89`)

All benchmarked with `llama-bench` on an idle GPU (24GB fully free, no
contention — cleaner numbers than the Proxmox box's shared-host noise):

- **Matched KV cache types matter far more than which type.** Every
  combination where `-ctk`/`-ctv` differ (e.g. `q4_0`/`q8_0`) pays a **~3x
  prompt-processing penalty** (870-1160 t/s vs ~3000 t/s) — llama.cpp's
  fused attention kernels have a fast path for matched-precision K/V and
  fall back to something much slower otherwise. Always keep `-ctk` and
  `-ctv` identical.
- **Among matched pairs, quantization level made ~no difference in
  speed** — `q4_0/q4_0`, `q8_0/q8_0`, and `f16/f16` all landed at
  ~3000-3040 t/s pp / ~49 t/s tg, within noise of each other. Unlike the
  6GB card, there's no throughput reason to quantize KV cache here — it's
  a pure VRAM-savings knob on this GPU. Kept `q4_0/q4_0` since VRAM is
  already comfortable (~17GB model + ample headroom) and it's what was
  already validated in production.
  - **f16/f16 does NOT reliably fit at the full 131072 context** — OOMs
    on the model's `rs cache` (recurrent-state cache for the
    Gated-DeltaNet layers, separate from the normal KV cache allocation)
    at just ~598MB needed, on a fully-idle 24GB card. Reproduced on both
    the pre-update and freshly-rebuilt llama.cpp — not a version bug, a
    real memory-scaling characteristic of this hybrid architecture at
    very large context. f16 **does** work fine at 65536 context (20.7GB
    used). If context needs to go back up near 131072, stick to a
    quantized KV cache type.
- **`-b`/`-ub`**: swept `-b` 2048/4096/8192 × `-ub` 512/1024/2048 (9
  combos) — all within noise (2957-3042 t/s pp, ~48.95 t/s tg), smaller
  values marginally ahead. Changed from `-b 8192 -ub 1024` to
  **`-b 2048 -ub 512`** — marginal speed win, smaller compute-buffer VRAM
  footprint, no downside found.
- **Speculative decoding (`--spec-type draft-mtp`) is a real, large
  win** — confirmed with an actual generation request on the same prompt,
  not just theory: **72.9 t/s with spec decoding vs 48.1 t/s without, a
  ~51% speedup.** Live production logs separately showed 55-66% draft
  token acceptance rate. Keep this on; it's the single biggest lever on
  this box given the model ships its own MTP draft head for free.
- **`--flash-attn on` vs `auto`**: identical on Ada Lovelace (unlike the
  2060) — either is fine.

**Gemma2-9B**, same methodology:

- Same matched-vs-mismatched KV pattern as the 27B model, **more extreme**:
  mismatched types cost a **~15-18x** pp penalty here (500-870 t/s vs
  8600-9600 t/s for matched), vs. ~3x on the 27B model.
- Among matched pairs, **`f16/f16` was the clear winner** — 9555 pp / 128.6
  tg, ahead of both `q4_0/q4_0` (9235/119.5) and `q8_0/q8_0` (9186/121.1).
  Unlike the 27B model where matched-pair quant level didn't matter, here
  it did, and f16 costs nothing extra worth caring about: the model is
  only 5.36GB and its native context is capped at 8192, so f16 KV cache is
  tiny in absolute terms regardless. Used `f16/f16` in the preset.
- `-b`/`-ub` sweep was flat (within noise across 1024-4096 / 256-1024) —
  kept `-b 2048 -ub 512` for consistency with the 27B model rather than
  chasing noise-level differences.

### `--sleep-idle-seconds 300`

Added per request — after 5 minutes with no real inference traffic
(`GET /health`, `/props`, `/models` don't count as activity and don't reset
the timer), the server unloads the model, its KV cache, and the 16GB prompt
cache from VRAM/RAM. The next request triggers an automatic reload. For a
27B model this reload isn't instant — expect the first message after a
quiet period to be noticeably slower than normal. `GET /props` reports
`sleeping: true/false` if you need to check state without triggering a
wake.

### llama.cpp version

Rebuilt from a fresh `git pull` (496 commits ahead of what was previously
built) — mainly done to check whether it'd fix the `rs cache` OOM at full
context (it didn't; that's a real constraint, not a build-age bug). Build
command, from `/home/jvhti/llama.cpp`:

```bash
PATH=/opt/cuda/bin:$PATH CUDAToolkit_ROOT=/opt/cuda \
  cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=89 -DCMAKE_BUILD_TYPE=Release
PATH=/opt/cuda/bin:$PATH cmake --build build --config Release -j16
```

---

## General llama.cpp gotchas hit on both boxes

- **`llama-cli` drops into interactive chat mode** after finishing a
  `-p`/`-n`-bounded prompt instead of exiting — don't script around it
  expecting a clean exit. Use `llama-server` + a real HTTP request for any
  scripted/automated test instead.
- **`llama-bench` doesn't exercise server-only features** (router mode,
  `--spec-type`, `--sleep-idle-seconds`) — those need an actual
  `llama-server` instance and a real request to validate, `llama-bench`
  only covers raw model/backend throughput (`-fa`, `-ctk`/`-ctv`,
  `-b`/`-ub`, etc.).
- **`--reasoning off` (or the model-family-specific equivalent) belongs on
  the server**, not relied upon from the client, if a Qwen3-family model
  is involved and thinking mode isn't wanted — client toggles (at least
  Open WebUI's) aren't guaranteed to actually reach the backend request.
