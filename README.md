# istat-ndc-cicd

Delivery machinery for the new NDC platform services on OpenShift: the one-shot
infrastructure bootstrap and the Tekton pipelines, both kept as code.

| Directory | Contents | Status |
|---|---|---|
| `bootstrap/` | Namespaces, quotas, deployer ServiceAccount, RBAC, pipeline workspace — the bundle INFRA/OPS applies once | ready to review |
| `tekton/` | Pipeline, Tasks, Triggers and PipelineRun templates — see [tekton/README.md](tekton/README.md) | ready to review |
| `scripts/` | `verify-target.sh` (run this first on a new cluster), `validate.sh`, `simulate-webhook.sh` | |

Naming note: the `istat-ndc` root is a placeholder, chosen to make explicit that these
resources do not reuse the legacy `ndc-*` namespaces. It is meant to be finalised together
with INFRA/OPS; changing it is a search-and-replace plus a re-apply.

## Bootstrap

```sh
oc apply -k bootstrap/
```

This creates:

- namespaces `istat-ndc-{cicd,dev,test,prod}` with starting quotas and limit ranges;
- the `deployer` ServiceAccount in `istat-ndc-cicd`;
- role bindings granting `deployer` the `edit` role on **dev and test only**;
- a 5Gi PersistentVolumeClaim for pipeline workspaces (cluster default storage class).

`bootstrap/31-rbac-prod.yaml` is intentionally excluded from the kustomization. Production
remains governed by the existing blue/green pipelines; the new pipeline gets access to
`istat-ndc-prod` only through a separate, deliberate apply.

### Verifying the result

```sh
oc get ns istat-ndc-cicd istat-ndc-dev istat-ndc-test istat-ndc-prod
oc get sa deployer -n istat-ndc-cicd

SA=system:serviceaccount:istat-ndc-cicd:deployer
oc auth can-i create deployments -n istat-ndc-dev  --as=$SA   # yes
oc auth can-i create deployments -n istat-ndc-prod --as=$SA   # no
oc auth can-i get    nodes                         --as=$SA   # no
```

The last two commands are the point of the design: the deploy identity is scoped to the
environments it owns, and holds nothing at cluster level.

## Before the first deploy on a new cluster

```sh
oc login … && ./scripts/verify-target.sh
```

Read-only. It reports where the cluster differs from what these manifests were tested against:
OpenShift and Pipelines versions, whether the tasks and ClusterRoles the pipeline relies on
exist, storage classes, namespaces missing a LimitRange next to their quota, and whether the
cluster can actually pull from the registry. Each difference has a documented variant in the
proposal; the point is to choose the variant before the first deploy rather than during it.

## Validating changes

```sh
./scripts/validate.sh
```

Renders both kustomizations and schema-checks them; when a cluster session exists it also runs
`oc apply --dry-run=server`, which is the only real validation available for Tekton resources
since they have no published JSON schemas.
