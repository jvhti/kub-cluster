# Gitea Actions: runners, workflow gotchas, and checking runs via the API

A runbook for this cluster's self-hosted Gitea Actions setup
(`infrastructure/controllers/gitea-runner-amd64/` and `-arm64/`) — written up
after standing up the first real workflow (`memogram-build`, which builds
[usememos/memogram](https://github.com/usememos/memogram) into a multi-arch
image pushed to Gitea's own container registry, since memogram itself
publishes no container image). Read this before debugging a new workflow;
most early failures here aren't bugs in the workflow's own logic.

## Checking runs/logs via the API, not the browser

Gitea's Actions UI works, but `scripts/gitea-api.sh` (checked into this repo)
is faster and doesn't need a logged-in browser session — useful since the
same admin PAT already exists as a cluster Secret (`gitea-admin-pat`,
`default` ns — see CLAUDE.md's secrets table). Copy it to the k3s node (or
run from a shell already there) and:

```bash
# List recent runs across all workflows in a repo
./gitea-api.sh /api/v1/repos/jvhti/memogram-build/actions/tasks

# List jobs for a specific run (gives you numeric job IDs, which differ
# from the run number shown in the UI)
./gitea-api.sh /api/v1/repos/jvhti/memogram-build/actions/runs/5/jobs

# Get a job's full log
./gitea-api.sh /api/v1/repos/jvhti/memogram-build/actions/jobs/14/logs

# Manually dispatch a workflow_dispatch-triggered workflow
./gitea-api.sh /api/v1/repos/jvhti/memogram-build/actions/workflows/build.yml/dispatches \
  -X POST -d '{"ref":"main"}'
```

Each call spins up a short-lived scratch pod in the `gitea` namespace
(auto-deleted via `--rm`) rather than needing curl/a token on the caller's
own machine. See the full Gitea API surface via `GET /swagger.v1.json` if
you need an endpoint not listed here — it's not linked from the UI but is
served directly by the instance.

## Runner setup: the two chart-level gotchas

Both `gitea-runner-amd64`/`-arm64` use the official
`gitea-charts/actions` Helm chart (`https://dl.gitea.com/charts/`), one
instance per architecture so a workflow matrix can build native images on
each rather than relying on QEMU emulation.

### `statefulset.nodeSelector` with more than one key breaks the chart

The chart's `statefulset.yaml` template emits `nodeSelector:` as a
**separate block per top-level key** instead of merging them into one map.
Two keys (e.g. `kubernetes.io/arch` + `kubernetes.io/hostname`) produces an
invalid manifest — `kustomize build --enable-helm` fails outright with
`mapping key "nodeSelector" already defined`, which shows up in ArgoCD as
the whole Application stuck in `Unknown` sync status with a
`ComparisonError` condition, not a normal sync failure. Confirmed via
`helm template` against chart version `0.1.2`.

Fix: use exactly **one** `nodeSelector` key. `kubernetes.io/hostname` alone
is enough here since each node is definitionally one architecture anyway.

### `.runner` doesn't pick up config.yaml changes after first registration

A runner's labels are read from `config.yaml` (the chart's
`statefulset.runner.config`) **only at first registration** — after that,
they're cached in `/data/.runner` on the runner's own PVC, and further
`config.yaml` edits (even after ArgoCD syncs the new ConfigMap) have no
effect on an already-registered runner. If a label change doesn't seem to
take effect:

```bash
kubectl exec -n gitea-runner-<arch> gitea-runner-<arch>-runner-0 -c runner -- rm -f /data/.runner
kubectl delete pod gitea-runner-<arch>-runner-0 -n gitea-runner-<arch>
```

Deleting the pod alone isn't enough if `.runner` still exists — it has to
actually be removed for the runner to re-register with the new labels on
next boot. Verify with `kubectl exec ... -- cat /data/.runner` after the
restart.

## Workflow-writing gotchas (all confirmed live, `memogram-build`'s first few runs)

### Runner labels must use `docker://` schema, not `host`

The act_runner **`runner` container itself has no `docker` binary at all**
— only the `dind` sidecar does. A `host`-schema label
(`runner.labels: ["amd64:host"]`) runs job steps directly in the runner
container, so any step shelling out to `docker` fails immediately with
`docker: command not found` (exit 127).

Fix: use `docker://<image>` schema instead (e.g.
`"amd64:docker://docker:27-cli"`) — this runs each step in a fresh
container pulled by the DinD daemon, with its socket auto-mounted by
act_runner. `docker:27-cli` bundles both the CLI and the `buildx` plugin,
enough for `docker build` / `docker buildx imagetools`.

### `docker:27-cli` has no `bash` — steps need `shell: sh`

Gitea Actions defaults multi-line `run:` steps to `bash`, same as GitHub
Actions. `docker:27-cli` is Alpine-based with only `/bin/sh` (ash) —
without an explicit shell, every multi-line step fails with `bash:
executable file not found in $PATH` (exit 127). Set
`defaults.run.shell: sh` at the workflow level (or per-job) so every step
uses `sh -e {0}` instead. Confirmed this maps correctly via `act`'s own
`ShellCommand()` (the engine Gitea Actions is built on).

### `GITEA_TOKEN` needs `permissions: packages: write` explicitly — there's no UI toggle for it

The auto-injected `${{ secrets.GITEA_TOKEN }}` failed `docker login` with
`unauthorized` even though the exact same registry accepted a manually
tested admin PAT — so this isn't a registry or credentials-mechanism
problem, it's a token-scope one. Per Gitea's own
`services/actions/token_permission_design.md` (not surfaced in the rendered
docs site at the time of writing): the **Packages** scope is deliberately
"designed separately" from Code/Issues/etc., is **not covered by the
repo's default `TokenPermissionMode`** (Permissive vs Restricted), and is
explicitly noted as "currently hidden from the settings UI" — meaning
there is no repo settings page toggle to grant it. It must be requested in
the workflow file itself:

```yaml
permissions:
  packages: write
```

Confirmed live: adding this at the workflow level, with no other
permissions changes, is what let `docker login`/`docker push` succeed with
`GITEA_TOKEN`.

## Debugging checklist for a new workflow

If a run fails and it's not one of the above:
1. Check `Set up job` and `Complete job` durations too, not just the step
   that shows red — a step showing `0s` with a green check that's actually
   a Gitea/Postgres outage artifact looks identical to a real pass at a
   glance (see the pgpool-instability incident below).
2. Cross-check `kubectl get pods -n gitea` — if `gitea-postgresql-ha-pgpool`
   or any `gitea-postgresql-ha-postgresql-*` pod is restarting, the Actions
   API can return misleading transient `401`/`500`s or drop browser
   sessions entirely, unrelated to the workflow itself. See
   `applications/gitea/values.yaml`'s comment on the resource bump that
   fixed pgpool's healthcheck timeouts under load — if it recurs, that's
   the first thing to check, not the workflow.
3. Get the real job log via `scripts/gitea-api.sh .../jobs/<id>/logs`
   rather than trusting the UI's collapsed step view — Gitea's log masking
   redacts the actual secret value even in `run:` echo commands
   (`echo "***" | docker login ...`), so a masked-looking log line is
   normal, not evidence the secret is empty.
