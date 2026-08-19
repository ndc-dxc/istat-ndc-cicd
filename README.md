# istat-ndc-cicd

Delivery machinery for the new NDC platform services on OpenShift: the one-shot
infrastructure bootstrap and the Tekton pipelines, both kept as code.

| Directory | Contents | Status |
|---|---|---|
| `bootstrap/` | Namespaces, quotas, deployer ServiceAccount, RBAC, pipeline workspace — the bundle INFRA/OPS applies once | ready to review |
| `tekton/` | Pipeline, Tasks, Triggers and PipelineRun templates — see [tekton/README.md](tekton/README.md) | ready to review |
| `scripts/` | `verify-target.sh` (run this first on a new cluster), `validate.sh`, `simulate-webhook.sh` | |
| `docs/` | [day-one.md](docs/day-one.md), [cross-cluster.md](docs/cross-cluster.md), [repo-governance.md](docs/repo-governance.md) | |

**Two clusters.** Dev and test share one OpenShift cluster; production runs on another one,
operated by the ISTAT DevOps team. Nothing in this repository is applied to it and nothing here
holds credentials for it — we reach test, promotion is theirs. Read
[docs/cross-cluster.md](docs/cross-cluster.md) before anything else here makes sense.

Naming note: the `istat-ndc` root is a placeholder, chosen to make explicit that these
resources do not reuse the legacy `ndc-*` namespaces. It is meant to be finalised together
with INFRA/OPS; changing it is a search-and-replace plus a re-apply.

## Bootstrap

```sh
oc apply -k bootstrap/
```

Applied to the **dev/test cluster**. It creates:

- namespaces `istat-ndc-{cicd,dev,test}` with starting quotas and limit ranges;
- the `deployer` ServiceAccount in `istat-ndc-cicd`;
- role bindings granting `deployer` the `edit` role on **dev and test only**;
- a 5Gi PersistentVolumeClaim for pipeline workspaces (cluster default storage class).

There is no production namespace here. Production is a different cluster where this bundle is
never applied, so creating an empty `istat-ndc-prod` alongside dev and test would only describe
a topology that does not exist.

### Verifying the result

```sh
oc get ns istat-ndc-cicd istat-ndc-dev istat-ndc-test
oc get sa deployer -n istat-ndc-cicd

SA=system:serviceaccount:istat-ndc-cicd:deployer
oc auth can-i create deployments -n istat-ndc-dev  --as=$SA   # yes
oc auth can-i create deployments -n istat-ndc-test --as=$SA   # yes
oc auth can-i get    nodes                         --as=$SA   # no
```

The last command is the point of the design: the deploy identity is scoped to the environments
it owns and holds nothing at cluster level. Its distance from production is more than RBAC —
it has no route to that cluster at all.

## Before the first deploy on a new cluster

```sh
oc login <dev/test cluster> && ./scripts/verify-target.sh --role dev-test
oc login <prod cluster>     && ./scripts/verify-target.sh --role prod
```

Read-only, and run once per cluster with the matching role. It reports where each cluster
differs from what these manifests were tested against:
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

## Who can change production

On the cluster, production is out of the deploy identity's reach. But production is also
*described* — in `values-prod.yaml`, in the library chart, in the workflow that packages the
release — and those files live in our repositories, where RBAC has no say. `.github/CODEOWNERS`
plus branch protection is what reconstructs the separation of duties on that half of the path:
see [docs/repo-governance.md](docs/repo-governance.md).
