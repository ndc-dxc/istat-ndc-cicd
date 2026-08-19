#!/usr/bin/env bash
# Run this first, against the ISTAT cluster, before applying anything.
#
# Everything in this repository was built and tested against a local single-node OpenShift.
# This script reports where the real cluster differs, so surprises show up as a list of facts
# instead of as a failed deploy. It only reads.
#
#   oc login … && ./scripts/verify-target.sh
set -uo pipefail

NS_PREFIX="${NS_PREFIX:-istat-ndc}"
REGISTRY_HOST="${REGISTRY_HOST:-ghcr.io}"

# What the local replica had, for comparison.
BASELINE_OCP="4.22.7"
BASELINE_PIPELINES="1.23.1"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
head_() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }
echo "cluster: $(oc whoami --show-server)   user: $(oc whoami)"

head_ "Versions"
ocp="$(oc version -o json 2>/dev/null | grep -o '"openshiftVersion":[^,]*' | cut -d'"' -f4)"
[ -n "$ocp" ] && ok "OpenShift $ocp (local replica: $BASELINE_OCP)" || warn "could not read the OpenShift version"

csv="$(oc get csv -A 2>/dev/null | grep -i 'openshift-pipelines-operator' | awk '{print $2, $3}' | head -1)"
if [ -n "$csv" ]; then ok "OpenShift Pipelines: $csv (local replica: $BASELINE_PIPELINES)"
else bad "OpenShift Pipelines operator not found — the pipelines cannot run"; fi

head_ "What the pipeline depends on"
if oc get task git-clone -n openshift-pipelines >/dev/null 2>&1; then
  ok "git-clone resolvable in openshift-pipelines (cluster resolver)"
else
  bad "no git-clone task in openshift-pipelines: switch the taskRef to a vendored copy"
fi

if oc get clusterrole pipelines-scc-clusterrole >/dev/null 2>&1; then
  ok "pipelines-scc-clusterrole exists (bootstrap grants it in $NS_PREFIX-cicd)"
else
  bad "pipelines-scc-clusterrole missing — pipeline pods will not be admitted"
fi

if oc get clusterrole tekton-triggers-eventlistener-clusterroles >/dev/null 2>&1; then
  ok "tekton-triggers-eventlistener-clusterroles exists (needed for the webhook variant)"
else
  warn "trigger ClusterRole missing — only the GitHub-Actions-calls-the-API variant will work"
fi

head_ "Storage"
sc="$(oc get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{" (default: "}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{") "}{end}' 2>/dev/null)"
[ -n "$sc" ] && ok "storage classes: $sc" || bad "no storage class: the workspace PVC cannot be provisioned"

head_ "Namespaces"
for env in cicd dev test prod; do
  ns="$NS_PREFIX-$env"
  if oc get ns "$ns" >/dev/null 2>&1; then
    q="$(oc get resourcequota -n "$ns" --no-headers 2>/dev/null | wc -l)"
    l="$(oc get limitrange   -n "$ns" --no-headers 2>/dev/null | wc -l)"
    ok "$ns exists (quotas: $q, limit ranges: $l)"
    # A quota without a limit range is the failure that costs an afternoon: Tekton's own init
    # containers declare no requests, and every PipelineRun is rejected.
    [ "$q" -gt 0 ] && [ "$l" -eq 0 ] && bad "  $ns has a quota but no LimitRange — pods without explicit resources will be rejected"
  else
    warn "$ns does not exist yet (created by bootstrap/)"
  fi
done

head_ "Image egress"
echo "  checking whether the cluster can pull from $REGISTRY_HOST …"
probe="egress-probe-$RANDOM"
if oc run "$probe" -n "${NS_PREFIX}-dev" --restart=Never --image="$REGISTRY_HOST/ndc-dxc/istat-ndc-sample-service:latest" \
     --command -- true >/dev/null 2>&1; then
  for _ in $(seq 1 20); do
    reason="$(oc get pod "$probe" -n "${NS_PREFIX}-dev" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)"
    case "$reason" in
      ErrImagePull|ImagePullBackOff) bad "the cluster cannot pull from $REGISTRY_HOST — use the mirror variant"; break ;;
      "") ok "image pulled from $REGISTRY_HOST"; break ;;
    esac
    sleep 3
  done
  oc delete pod "$probe" -n "${NS_PREFIX}-dev" --wait=false >/dev/null 2>&1
else
  warn "could not run the egress probe (namespace missing or no permission) — test it after bootstrap"
fi

head_ "Summary"
echo "  Differences above are not necessarily problems: each has a documented variant in the"
echo "  proposal (registry mirror, no inbound webhook, vendored tasks). What matters is deciding"
echo "  which variant applies before the first deploy rather than during it."
