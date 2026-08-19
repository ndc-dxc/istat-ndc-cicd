#!/usr/bin/env bash
# Validates the manifests in this repository. Runs the schema checks that need no cluster, and
# adds a server-side dry run when one is reachable — the only way to really validate Tekton
# resources, since no public JSON schemas exist for them.
set -euo pipefail
cd "$(dirname "$(realpath "$0")")/.."

OPENSHIFT_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/openshift/v4.15-strict/{{ .ResourceKind }}_{{ .Group }}_{{ .ResourceAPIVersion }}.json'

for dir in bootstrap tekton; do
  echo "==> $dir: render"
  oc kustomize "$dir" > "/tmp/$dir-rendered.yaml"

  echo "==> $dir: schema check (Tekton kinds are skipped — no published schemas)"
  kubeconform -strict -summary -ignore-missing-schemas \
    -schema-location default \
    -schema-location "$OPENSHIFT_SCHEMAS" \
    "/tmp/$dir-rendered.yaml"
done

if oc whoami >/dev/null 2>&1; then
  for dir in bootstrap tekton; do
    echo "==> $dir: server-side dry run against $(oc whoami --show-server)"
    oc apply --dry-run=server -f "/tmp/$dir-rendered.yaml"
  done
else
  echo "==> no cluster session; skipping the server-side dry run (oc login to include it)"
fi

echo "==> validation finished"
