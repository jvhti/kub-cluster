# Fronting an app with oauth2-proxy + Authelia

A runbook + lessons-learned for putting an app behind the
Authelia-backed oauth2-proxy login gate (what Longhorn already had; what
degoog got when it went public — see `applications/degoog/` and
`infrastructure/controllers/oauth2-proxy-degoog/`). Most of this was
learned the hard way debugging a real `invalid_client` / 500 loop on
degoog's first deploy — read the "Learnings" section before assuming a
login failure is a new, novel bug.

## Quick guide: adding a new app behind the gate

oauth2-proxy here is **one instance per app**, not a shared multi-host
proxy — see "Why one instance per app" below for why that's not just
extra ceremony. To add a new app (call it `foo`, hostname
`foo.jvos.dev`):

1. **New oauth2-proxy instance**: copy
   `infrastructure/controllers/oauth2-proxy-degoog/` to
   `infrastructure/controllers/oauth2-proxy-foo/`. In `values.yaml`,
   change `existingSecret`, `redirect-url`
   (`https://foo.jvos.dev/oauth2/callback`), and `upstream`
   (`http://foo.foo.svc.cluster.local:<port>`). In `secrets.yaml`, rename
   the Secret and update its `kubectl create secret` comment. Add a
   `reference-grant.yaml` allowing `foo`'s namespace to reference this
   `oauth2-proxy-foo` Service.
2. **New Authelia OIDC client**: in
   `infrastructure/controllers/authelia/values.yaml`, add a
   `pod.extraVolumes`/`extraVolumeMounts` pair for a new
   `authelia-oidc-client-foo` Secret (mirror the `-degoog` entries), and a
   new `identity_providers.oidc.clients[]` entry with `client_id:
   'oauth2-proxy-foo'`, `redirect_uris: ['https://foo.jvos.dev/oauth2/callback']`.
   **Do not set `token_endpoint_auth_method`** — leave it unset (see
   Learning #1 below).
3. **HTTPRoute**: point `foo`'s `backendRefs` at `oauth2-proxy-foo`
   (namespace `oauth2-proxy-foo`, port 80), not straight at `foo`'s own
   Service — same shape as `applications/degoog/httproute.yaml`.
4. **Generate the credential pair correctly** (see the exact commands
   under "Generating a client-secret pair" below — this is where the
   real bugs live, not in the YAML).
5. Commit, push, let ArgoCD sync, `kubectl rollout restart` both
   `deploy/authelia` and the new oauth2-proxy instance (neither hot-reloads
   Secret/ConfigMap changes), then test with a **single**, deliberate
   browser login — see Learning #3 on why a hasty double-attempt produces
   misleading logs.

## Why one instance per app

oauth2-proxy's legacy CLI-flag config (`extraArgs.upstream`, what every
instance in this repo uses — see `infrastructure/controllers/oauth2-proxy/values.yaml`'s
own comment on why `alphaConfig` was rejected) is **single-upstream,
single-redirect-url**: one backend, one Host, no per-request routing.

The obvious-looking alternative — oauth2-proxy's `--alpha-config` with
`upstreamConfig.upstreams[]` — does support multiple upstreams, but
routing is **path-regex based, not Host-header based** (confirmed against
oauth2-proxy's own docs). Since every app here serves its root at `/`,
one shared instance in alpha-config mode could not tell
`longhorn.jvos.dev` apart from `search.jvos.dev` — both would match the
same `path: "^/"` rule. A second whole instance (own redirect-url, own
upstream, own OIDC client/credentials) sidesteps this entirely and keeps
every existing app's working setup untouched when adding a new one.

## Generating a client-secret pair (read this before running the commands)

Authelia validates the OIDC client secret against a **hash**; oauth2-proxy
authenticates with the **plaintext**. Same underlying credential, two
forms, generated once and split across two Secrets in two namespaces —
get this wrong and you get a silent, confusing `invalid_client` at the
token endpoint (see Learning #2).

There is no `docker`/`podman` on the cluster node (k3s uses containerd
directly), so `authelia crypto hash generate` — which needs the real
`authelia` binary — has to run **inside the live Authelia pod** instead
of a scratch container:

```bash
CLIENT_SECRET=$(openssl rand -hex 32)

# NOT --random — see Learning #2. Passing both --random and --password
# together silently ignores --password and hashes a DIFFERENT,
# internally-generated password instead, while only printing the
# digest — you get a hash for a secret you never see or use.
HASH=$(kubectl exec -n authelia deploy/authelia -- \
  authelia crypto hash generate pbkdf2 --password "$CLIENT_SECRET" \
  2>&1 | grep -oP '(?<=Digest: ).*')

# Verify the pair actually matches BEFORE writing either Secret —
# cheap, catches the mistake above immediately instead of after two
# `kubectl apply`s and a confusing round of log-reading.
kubectl exec -n authelia deploy/authelia -- \
  authelia crypto hash validate "$HASH" --password "$CLIENT_SECRET"
# must print exactly: "The password matches the digest."

kubectl create secret generic authelia-oidc-client-foo \
  --namespace authelia \
  --from-literal=client-secret-hash="$HASH" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic oauth2-proxy-foo-credentials \
  --namespace oauth2-proxy-foo \
  --from-literal=client-id="oauth2-proxy-foo" \
  --from-literal=client-secret="$CLIENT_SECRET" \
  --from-literal=cookie-secret="$(openssl rand -base64 32 | head -c 32 | base64)" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment/authelia -n authelia
kubectl rollout restart deployment/oauth2-proxy-foo -n oauth2-proxy-foo
```

Both restarts are required — Authelia mounts the hash via a Secret
volume (`pod.extraVolumes`) and oauth2-proxy reads the plaintext via an
env var from `config.existingSecret`; neither picks up a changed Secret
without a pod restart.

## Learnings (from a real debugging session, degoog's first deploy)

### 1. Don't set `token_endpoint_auth_method` — leave it on Authelia's default

Authelia's spec-compliant default for a confidential client (no
`public: true`) is `client_secret_basic` (HTTP Basic auth at the token
endpoint) — confirmed against Authelia's own docs, not assumed. The
working Longhorn client has never set this field and has always used
that default successfully.

**Don't "fix" an `invalid_client` error by hardcoding
`token_endpoint_auth_method`.** An early error here read:

> `token_endpoint_auth_method' method 'client_secret_post', however the
> OAuth 2.0 client registration does not allow this method`

This is easy to misread as "oauth2-proxy sent `client_secret_post` and
Authelia rejected it" — it actually means the opposite: Authelia's
*current client config* was demanding `client_secret_post` (from a
previous bad edit, in this case) and rejecting oauth2-proxy's real
`client_secret_basic` request. Chasing this by pinning
`token_endpoint_auth_method` explicitly just moves which side is wrong;
the actual fix (see #2) was unrelated to auth method entirely. If you
genuinely need to know what method your client sends, read *Authelia's*
error message's "is configured to only support X" clause, not the first
clause — that names the requirement being violated, not what was sent.

### 2. `authelia crypto hash generate pbkdf2 --random --password X` ignores `--password`

The actual root cause of degoog's `invalid_client` / "the provided
client secret did not match the registered client secret" loop: the
hash-generation command was run with **both** `--random` and
`--password`. `--random` wins silently — the command prints a `Random
Password: ...` line (a password you never captured) and hashes *that*,
not the `--password` value. The script only captured the `Digest:` line,
paired it with the real intended secret, and applied both — producing a
cryptographically valid-looking pair that simply didn't match each
other. `kubectl logs` on oauth2-proxy just showed a generic `invalid_client`
token-exchange failure; the real signal was in **Authelia's** logs
(`kubectl logs -n authelia -l app.kubernetes.io/name=authelia`), which
spelled out "the provided client secret did not match the registered
client secret" — check that log, not just the proxy's, when a token
exchange fails.

The fix is procedural, not code: never pass `--random` when you're
supplying your own `--password`, and always run `crypto hash validate`
against the pair before applying either Secret (see the commands above).

### 3. A single login attempt can log as two different, contradictory errors

While mid-debugging, two Authelia errors landed in the *same second* —
one saying oauth2-proxy sent `client_secret_basic`, the other saying it
sent `client_secret_post` — which looked like inconsistent client
behavior across requests. In hindsight this was two separate login
attempts (browser retry/reload) landing close together, each carrying a
different authorization `code=` value, logged interleaved. Authorization
codes are single-use, so a retried login after a failed one will *always*
look like a different failure than the first, even when the underlying
cause (e.g. #2's mismatched secret) is identical and unchanged. When
debugging a login failure, match each Authelia log line to a specific
`code=` in the oauth2-proxy access log for that exact request before
concluding the behavior is actually inconsistent — don't average across
attempts.

### 4. Both restarts are required, and ConfigMap/Secret edits don't hot-reload

Covered above but worth repeating as its own point: after any change to
`infrastructure/controllers/authelia/values.yaml` (new client, changed
field) or to either Secret in a client pair, both `deploy/authelia` and
the relevant oauth2-proxy `Deployment` need `kubectl rollout restart`.
ArgoCD syncing the ConfigMap/Secret alone does not make either pod
re-read it.

### 5. `403` with an OAuth2 Proxy-branded page is success, not failure

Hitting `https://foo.jvos.dev/` with no session cookie correctly returns
HTTP `403` with oauth2-proxy's own sign-in page body (not a `302`
redirect to Authelia) — confirmed identical behavior on the known-working
Longhorn path. Don't read a `403` here as the gate being broken; it's
the expected "not authenticated yet" response in this chart's default
mode.
