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
| Serving mode | router mode, 2 models, swap on demand | router mode, 3 models, swap on demand |
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

### Using it (API endpoint)

**`http://192.168.1.18:8080`** — OpenAI-compatible (`/v1/chat/completions`,
`/v1/models`, etc.), no auth, plain HTTP, LAN-only (`--host 0.0.0.0`, not
exposed externally). `192.168.1.18` is a **DHCP lease on the LXC**, not a
static/reserved address — confirm it hasn't moved (`pct exec 139 -- ip -4
addr show eth0`) before assuming it's still current, especially after a
container or DHCP server restart. `GET /health` is the quickest liveness
check. See the router-mode section below for which `"model"` values to
pass in requests.

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

### Using it (API endpoint)

**`http://192.168.1.211:8090`** — OpenAI-compatible, no auth, plain HTTP,
LAN-only (`--host 0.0.0.0`, not exposed externally). This is the host's own
static LAN IP (not a container/DHCP lease like the Proxmox box), so it's
stable. `overkill` also has a Tailscale interface (`tailscale0`,
`100.100.14.52` at last check) if remote access off-LAN is ever needed —
untested for this purpose, would need Tailscale ACLs/routing configured to
actually work, not just being present. `GET /health` for liveness. See the
router-mode section below for which `"model"` values to pass in requests.

### Models: router mode, three models

Same rationale as the Proxmox box, different cause — a single 27B model
already uses ~22.4-22.7GB of the 24GB card at full 131072 context, so
there's no room to keep a second (let alone third) model resident
simultaneously. Converted from a single always-on process to router mode
once a second model was added, then a third.

- **`qwen3.8-27b`** — `Qwen3.8-27B-Q4_K_M.gguf`
  (`/home/jvhti/Models/`), Qwen3.5-family hybrid Gated-DeltaNet
  architecture, same family as the 4B model on the Proxmox box, at 27B
  scale. Has a multi-token-prediction (MTP) head baked in as an extra
  model layer, used for speculative decoding (see below).
- **`huihui-qwen3.6-27b`** — `Huihui-Qwen3.6-27B-abliterated-Q4_K.gguf`,
  from `huihui-ai/Huihui-Qwen3.6-27B-abliterated-MTP-GGUF` on Hugging Face.
  Same `qwen35` architecture family as `qwen3.8-27b` (65 layers, native
  `context_length = 262144` per `gguf_dump.py`, though capped to 131072 in
  the preset to match available VRAM). Kept the MTP head, so speculative
  decoding works here too — confirmed live (`draft_n_accepted: 40/55` on a
  test request). Near-identical `llama-bench` profile to `qwen3.8-27b`
  (~3000 pp / ~49.3-49.9 tg on matched KV types), so reused the same tuned
  settings rather than re-deriving them.
- A third, smaller model registered alongside them (HF-cache layout under
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

[huihui-qwen3.6-27b]
model         = /home/jvhti/Models/Huihui-Qwen3.6-27B-abliterated-Q4_K.gguf
ctx-size      = 131072
cache-type-k  = q4_0
cache-type-v  = q4_0
batch-size    = 2048
ubatch-size   = 512
cache-prompt  = 1
cache-ram     = 16384
spec-type     = draft-mtp
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
box — request `"model": "qwen3.8-27b"`, `"model": "huihui-qwen3.6-27b"`, or
`"model": "gemma2-9b"` in the request body (all three appear in `GET
/v1/models`, actual `[section]` names are whatever the preset uses). Note
the Gemma2 model does **not** have `--reasoning off` set (unlike the
Proxmox preset) — it's not a reasoning-capable model in the first place, so
it wasn't needed; both 27B models still show `reasoning_content` in
responses by design (thinking mode not disabled), so budget `max_tokens`
generously with them — a bare `reasoning_effort: low` still consumed 60+
tokens purely on the reasoning preamble in testing before any answer text
appeared.

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

---

## TTS: Kokoro-82M on the Proxmox LXC (`192.168.1.18:8880`)

Separate from the LLM inference above, the same Proxmox LXC (`192.168.1.18`)
also serves Text-to-Speech on port `8880`, consumed by Open WebUI's "openai"
TTS engine (see `applications/openwebui/openwebui.yaml`'s `AUDIO_TTS_*` envs).
Like the LLM, it is **not** part of the k3s cluster / ArgoCD-managed.

### Why Kokoro (not Piper)

- Piper has **no female pt-BR voice at any quality tier** (only male:
  `edresson`, `cadu`, `faber`, `jeff`) — see
  [rhasspy/piper#766](https://github.com/rhasspy/piper/issues/766), an open
  request for exactly this.
- **Kokoro-82M** provides `pf_dora` (pt-BR female) plus a raft of `af_*`
  English female voices, is Apache-2.0, ~82M params (~350MB fp32), and runs
  fast enough on CPU for chat TTS (see "Runs on CPU" below).

### Runs on CPU (not GPU) — why

Tried GPU first (Kokoro's 800MiB resident footprint seemed to coexist with
the LLM), but it **conflicts on the 6GB card**: llama-server needs contiguous
free VRAM to load a model, and with Kokoro resident the router aborted with
`W common_fit_params: failed to fit params to free device memory:
n_gpu_layers already set by user to 99, abort`. Observed split was
llama-server 4932MiB + Kokoro 800MiB = 5732MiB/6144MiB, leaving only
~400MiB — not enough for an LLM load.

Resolution: **run Kokoro on CPU** (`USE_GPU=false`). It uses 0 GPU VRAM, so
llama-server gets the full 6GB back. Kokoro-82M is fast enough on CPU for
short-sentence synthesis (a ~50-char sentence synthesizes in about a second,
well within real-time for chat TTS). This is the documented configuration;
nothing is lost by not using the GPU.

### Server: `remsky/Kokoro-FastAPI`

The GitHub repo (already has all the `.pt` voice packs committed, including
`pf_dora`, `af_heart`, etc. in `api/src/voices/v1_0/`). Exposes
`POST /v1/audio/speech` (OpenAI-compatible) plus `/v1/models`, `/health`,
and a web UI at `/web`. Native install matched to llama.cpp (no Docker).

#### Install (uv, systemd) on the LXC

```bash
pct exec 139 -- bash - <<'EOF'
set -eux
# Prereqs (uv runtime + espeak-ng phonemizer fallback)
apt-get update && apt-get install -y espeak-ng ffmpeg
curl -LsSf https://astral.sh/uv/install.sh | sh   # -> /root/.local/bin/uv

# Clone the repo (Python 3.12 venv managed by uv)
git clone https://github.com/remsky/Kokoro-FastAPI.git /opt/Kokoro-FastAPI
cd /opt/Kokoro-FastAPI
export PATH=/root/.local/bin:$PATH
uv venv .venv                                       # creates CPython 3.12 env
# Installs deps + torch: use the cpu extra here (GPU conflicts, see above).
# Were GPU ever wanted: `uv pip install -e ".[gpu]"` (torch 2.8.0+cu126).
uv pip install -e ".[cpu]"

# Download the model into the tree (checksum-verified)
. .venv/bin/activate
export PYTHONPATH=$PWD:$PWD/api
uv run --no-sync python docker/scripts/download_model.py --output api/src/models/v1_0
EOF
```

Then the systemd unit. The `MODEL_DIR`/`VOICES_DIR` envs are **required**:
the repo's config defaults to container-absolute `/app/...` paths that don't
exist on this host; setting them relative (`src/models`, `src/voices/v1_0`)
makes `api/src/core/paths.py` resolve them against `$PWD/api` correctly.
`USE_GPU=false` is what keeps it off the card.

```ini
# /etc/systemd/system/kokoro-tts.service
[Unit]
Description=Kokoro TTS server (OpenAI-compatible /v1/audio/speech)
After=network-online.target
Wants=network-online.target

[Service]
User=root
WorkingDirectory=/opt/Kokoro-FastAPI
Environment=USE_GPU=false
Environment=PYTHONPATH=/opt/Kokoro-FastAPI:/opt/Kokoro-FastAPI/api
Environment=MODEL_DIR=src/models
Environment=VOICES_DIR=src/voices/v1_0
Environment=WEB_PLAYER_PATH=/opt/Kokoro-FastAPI/web
Environment=API_LOG_LEVEL=INFO
Environment=HOME=/root
ExecStart=/opt/Kokoro-FastAPI/.venv/bin/uvicorn api.src.main:app --host 0.0.0.0 --port 8880
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
pct exec 139 -- systemctl daemon-reload
pct exec 139 -- systemctl enable --now kokoro-tts
```

Startup log should show `Initializing Kokoro V1 on cpu` and `Running on CPU`
plus `68 voice packs loaded`. If it ever says `on cuda`, `USE_GPU` wasn't
picked up — the LLM will then fail to load (see "Runs on CPU" above).

#### Verify

```bash
# liveness + voice count
curl http://192.168.1.18:8880/health

# a real synthesis (pt-BR female)
curl -X POST http://192.168.1.18:8880/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{"model":"kokoro","input":"Olá mundo!","voice":"pf_dora","response_format":"mp3"}' \
  --output /tmp/ola.mp3

# and en-US female
curl -X POST http://192.168.1.18:8880/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{"model":"kokoro","input":"Hello world!","voice":"af_heart","response_format":"mp3"}' \
  --output /tmp/hello.mp3
```

`pf_dora` (pt-BR female) and `af_heart` / `af_bella` / `af_jessica` /
`af_sky` (en-US females) are the relevant voices; `pf_dora` is the Open
WebUI default referenced in `openwebui.yaml`. Voices can also be blended
(`voice: "af_sky+af_bella"`).

#### Open WebUI side

`openwebui.yaml` already sets the matching envs; in the UI (Admin → Settings
→ Audio → TTS) the values should read: Engine `OpenAI`, API Base URL
`http://192.168.1.18:8880/v1`, API Key `not-needed`, Model `kokoro`, Voice
`pf_dora`. These are overridable in the UI at runtime; the env vars just
seed the defaults on first boot.
