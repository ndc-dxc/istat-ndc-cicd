#!/usr/bin/env bash
# Survey a cluster before applying or deploying anything. Read-only.
#
# Dev/test and production live on *different clusters* (docs/cross-cluster.md), so this runs
# twice, with different expectations each time:
#
#   oc login <dev/test cluster> && ./scripts/verify-target.sh --role dev-test
#   oc login <prod cluster>     && ./scripts/verify-target.sh --role prod
#
# Everything here was built against a local single-node OpenShift. The point of the script is
# to turn the differences into a list of facts instead of a failed deploy.
set -uo pipefail

ROLE="dev-test"
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="${2:?--role needs a value: dev-test or prod}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (expected --role dev-test|prod)" >&2; exit 2 ;;
  esac
done
case "$ROLE" in dev-test|prod) ;; *) echo "--role must be dev-test or prod" >&2; exit 2 ;; esac

NS_PREFIX="${NS_PREFIX:-istat-ndc}"
REGISTRY_HOST="${REGISTRY_HOST:-ghcr.io}"
# Images are tagged by commit SHA only, so there is no stable tag to probe with: pass a real
# one. Without it the probe still distinguishes "registry unreachable" from "no such image".
PROBE_IMAGE="${PROBE_IMAGE:-$REGISTRY_HOST/ndc-dxc/istat-ndc-sample-service:latest}"

# What the local replica had, for comparison.
BASELINE_OCP="4.22.7"
BASELINE_PIPELINES="1.23.1"

ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()   { printf '  \033[31m✗\033[0m %s\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
head_() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }
printf 'role: %s\ncluster: %s   user: %s\n' "$ROLE" "$(oc whoami --show-server)" "$(oc whoami)"

# ---------------------------------------------------------------- shared checks

check_version() {
  head_ "Versions"
  local ocp
  ocp="$(oc version -o json 2>/dev/null | grep -o '"openshiftVersion":[^,]*' | cut -d'"' -f4)"
  [ -n "$ocp" ] && ok "OpenShift $ocp (local replica: $BASELINE_OCP)" \
                || warn "could not read the OpenShift version (needs cluster-scoped read)"
}

# The chart never pins runAsUser precisely so that each namespace can assign its own UID from
# its own range. That has to hold on both clusters, or the same manifests behave differently.
check_scc_model() {
  local ns="$1"
  head_ "SCC and UID model ($ns)"
  if oc get scc restricted-v2 >/dev/null 2>&1; then
    ok "SCC restricted-v2 exists"
  else
    warn "cannot read SCCs (no cluster-scoped access) — verify with the cluster team"
  fi
  local range
  range="$(oc get ns "$ns" -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}' 2>/dev/null)"
  if [ -n "$range" ]; then
    ok "$ns assigns UIDs from $range"
    info "the chart sets runAsNonRoot but no runAsUser, so this range is what pods get"
  else
    warn "could not read the UID range of $ns"
  fi
}

# Can this cluster pull the image at all? On production we usually only have read access, so
# the probe is attempted only when permitted and otherwise handed over as a command to run.
check_registry() {
  local ns="$1"
  head_ "Image egress ($REGISTRY_HOST)"
  if ! oc get ns "$ns" >/dev/null 2>&1; then
    warn "namespace $ns not visible — cannot test the pull from here"
    return
  fi
  if [ "$(oc auth can-i create pods -n "$ns" 2>/dev/null)" != "yes" ]; then
    warn "no permission to create a probe pod in $ns (expected with read-only access)"
    info "ask the cluster team to run, or run it yourself where permitted:"
    info "  oc run egress-probe -n $ns --restart=Never --image=$PROBE_IMAGE --command -- true"
    info "  oc get pod egress-probe -n $ns -o jsonpath='{.status.containerStatuses[0].state}'"
    return
  fi
  local probe="egress-probe-$RANDOM" reason msg
  info "probe image: $PROBE_IMAGE"
  if oc run "$probe" -n "$ns" --restart=Never --image="$PROBE_IMAGE" --command -- true >/dev/null 2>&1; then
    for _ in $(seq 1 20); do
      reason="$(oc get pod "$probe" -n "$ns" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)"
      case "$reason" in
        ErrImagePull|ImagePullBackOff)
          msg="$(oc get pod "$probe" -n "$ns" -o jsonpath='{.status.containerStatuses[0].state.waiting.message}' 2>/dev/null)"
          # Reaching the registry and being refused by it are different answers. Only the
          # first one means the mirror variant applies; the rest is a wrong reference.
          if printf '%s' "$msg" | grep -qiE 'not found|manifest unknown|denied|unauthorized|authentication required'; then
            warn "$REGISTRY_HOST answered, but this image reference is not pullable"
            info "$msg"
            info "registry reachability is fine; re-run with PROBE_IMAGE=<repo>:<real sha> to confirm"
          else
            bad "the cluster cannot reach $REGISTRY_HOST — the mirror variant applies"
            info "$msg"
            info "then image.repository must be overridden in values for this cluster"
          fi
          break ;;
        "") ok "image pulled from $REGISTRY_HOST"; break ;;
      esac
      sleep 3
    done
    oc delete pod "$probe" -n "$ns" --wait=false >/dev/null 2>&1
  else
    warn "could not start the egress probe — test it after bootstrap"
  fi
}

check_route_domain() {
  local ns="$1"
  head_ "Route domain"
  local domain
  domain="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)"
  if [ -n "$domain" ]; then
    ok "apps domain: $domain"
  else
    domain="$(oc get route -n "$ns" -o jsonpath='{.items[0].spec.host}' 2>/dev/null)"
    [ -n "$domain" ] && ok "a Route in $ns resolves to: $domain" \
                     || warn "could not determine the Route domain (no cluster config read, no Route to sample)"
  fi
  info "it differs per cluster: any explicit route.host in values is cluster-specific"
}

# ---------------------------------------------------------------- dev/test profile

survey_dev_test() {
  check_version

  head_ "What the pipeline depends on"
  local csv
  csv="$(oc get csv -A 2>/dev/null | grep -i 'openshift-pipelines-operator' | awk '{print $2, $3}' | head -1)"
  if [ -n "$csv" ]; then ok "OpenShift Pipelines: $csv (local replica: $BASELINE_PIPELINES)"
  else bad "OpenShift Pipelines operator not found — the pipelines cannot run"; fi

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
  local sc
  sc="$(oc get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{" (default: "}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{") "}{end}' 2>/dev/null)"
  [ -n "$sc" ] && ok "storage classes: $sc" || bad "no storage class: the workspace PVC cannot be provisioned"

  head_ "Namespaces"
  # No production namespace here: production is a different cluster (docs/cross-cluster.md).
  local ns q l
  for env in cicd dev test; do
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
  if oc get ns "$NS_PREFIX-prod" >/dev/null 2>&1; then
    warn "$NS_PREFIX-prod exists on this cluster — expected only on the production cluster"
  fi

  check_scc_model "$NS_PREFIX-dev"
  check_registry  "$NS_PREFIX-dev"
  check_route_domain "$NS_PREFIX-dev"
}

# ---------------------------------------------------------------- prod profile

survey_prod() {
  local ns="${PROD_NAMESPACE:-$NS_PREFIX-prod}"
  echo
  info "This cluster is operated by the ISTAT DevOps team. Nothing here is applied by us:"
  info "we only check what genuinely crosses the boundary between the two clusters."

  check_version

  head_ "Access"
  if oc get ns "$ns" >/dev/null 2>&1; then
    ok "$ns is visible"
  else
    bad "$ns is not visible — read access on the production namespace is what makes drift detection possible"
  fi
  for verb in "create deployments" "update deployments" "create pods"; do
    if [ "$(oc auth can-i $verb -n "$ns" 2>/dev/null)" = "yes" ]; then
      warn "this account can '$verb' in $ns — more than the read-only access we asked for"
    fi
  done
  ok "no write access expected here: promotion and apply belong to the DevOps team"

  check_scc_model "$ns"
  check_registry  "$ns"
  check_route_domain "$ns"

  head_ "Descriptor drift"
  if oc get deploy -n "$ns" >/dev/null 2>&1; then
    ok "workloads readable — images currently running:"
    oc get deploy -n "$ns" -o jsonpath='{range .items[*]}    {.metadata.name}{"  "}{.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null
    info "compare these against the promotion record of the release that was applied:"
    info "a mismatch means production was changed outside the descriptors, and the next"
    info "render would silently revert it."
  else
    warn "cannot read workloads in $ns — drift between descriptors and reality stays invisible"
  fi
}

case "$ROLE" in
  dev-test) survey_dev_test ;;
  prod)     survey_prod ;;
esac

head_ "Summary"
echo "  Differences above are not necessarily problems: each has a documented variant in the"
echo "  proposal (registry mirror, no inbound webhook, vendored tasks). What matters is deciding"
echo "  which variant applies before the first deploy rather than during it."
