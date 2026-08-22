#!/bin/sh
# Calls Gitea's API from inside the cluster, authenticated with the
# gitea-admin-pat Secret (default namespace) — see CLAUDE.md's secrets
# table. Runs a short-lived scratch pod rather than needing curl/a token
# available on the caller's own machine; the pod is deleted automatically
# (--rm) whether the call succeeds or fails.
#
# Meant to be copied to the k3s node (or run from a shell already on it —
# see CLAUDE.md's access notes, kubectl is not configured on any dev
# machine) and invoked from there, since it shells out to `kubectl run`.
#
# Usage: gitea-api.sh <path> [extra curl args...]
# Examples:
#   gitea-api.sh /api/v1/repos/jvhti/memogram-build/actions/tasks
#   gitea-api.sh /api/v1/repos/jvhti/memogram-build/actions/runs/5/jobs
#   gitea-api.sh /api/v1/repos/jvhti/memogram-build/actions/jobs/14/logs
#   gitea-api.sh /api/v1/repos/jvhti/memogram-build/actions/workflows/build.yml/dispatches -X POST -d '{"ref":"main"}'
#
# See docs/gitea-actions.md for the full Actions runbook this script
# supports (checking run/job status and logs without the browser).
set -eu
PATH_ARG="$1"
shift
TOKEN=$(kubectl get secret gitea-admin-pat -n default -o jsonpath='{.data.token}' | base64 -d)
UNIQ=$(date +%s%N)
kubectl run -n gitea "gitea-api-${UNIQ}" --restart=Never --image=curlimages/curl --rm -i \
  --env="TOKEN=${TOKEN}" --command -- \
  sh -c "curl -s -H \"Authorization: token \$TOKEN\" $* \"http://gitea-http:3000${PATH_ARG}\""
