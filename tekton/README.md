# Tekton pipelines

One pipeline, `deploy-service`, deploys any service to any of its non-production environments.
The environment is a **parameter**, never a branch: promoting from dev to test means running
the same pipeline again with `env: test` and the *same* `imageTag`.

```
fetch-source ──> validate ──────────> deploy ─────────────────────> smoke
git-clone         helm lint            helm upgrade --install         curl /health
                  helm template        --atomic --wait                through the
                  kubeconform -strict  (auto rollback on failure)     Service address
                  [GATE]                                              [GATE]
```

## Installing

```sh
oc apply -k tekton/          # tasks, pipeline, triggers, listener route
```

Requires the bootstrap bundle (namespaces, `deployer` ServiceAccount, workspace PVC) to have
been applied first.

The webhook secret is not in git. Create it once per cluster:

```sh
oc create secret generic github-webhook-secret \
  --from-literal=secretToken="$(openssl rand -hex 32)" \
  -n istat-ndc-cicd
```

## Running it by hand

```sh
oc create -f tekton/examples/pipelinerun-manual.yaml
tkn pipelinerun logs -f -n istat-ndc-cicd
```

## How a deploy gets triggered

Two variants are implemented; which one is used is an ISTAT decision, and switching costs
nothing on our side.

**A — signed webhook (default).** After pushing the image, the build workflow POSTs a payload
to the listener's route, signed with an HMAC shared secret. Two interceptors stand in front of
the pipeline:

- the **GitHub interceptor** verifies the signature; unsigned or wrongly signed requests never
  reach a PipelineRun;
- the **CEL interceptor** then requires the repository to be under our owner, the environment
  to be `dev` or `test`, and the service name and image tag to match strict patterns — so no
  free-form string from the payload travels further.

`scripts/simulate-webhook.sh` sends exactly that request, which is how the chain is tested
without exposing anything to the internet. Sending it with a wrong secret is part of the test:
the listener must refuse it.

**B — no inbound access.** If ISTAT does not want an inbound route, the build workflow calls
the cluster API instead, creating the PipelineRun with a dedicated ServiceAccount token. The
pipeline, the tasks and the guards are unchanged; only the way the run is created differs.
In that case the listener, its route and the webhook secret are simply not deployed.

## Guardrails

- **Production is unreachable from here.** `helm-deploy` refuses any environment other than
  `dev` and `test`, and the `deployer` ServiceAccount has no rights on production namespaces.
  The guard is in the task and not only in the trigger, so it also holds for manual runs.
- **`--atomic --wait`** rolls back automatically when a rollout does not become healthy.
- **The validation gate runs before the cluster is touched**, so a malformed chart costs
  seconds rather than a broken namespace.
- **No shell parsing of pipeline inputs**: parameters are passed as typed task inputs.

## Notes on images and task resolution

`fetch-source` resolves `git-clone` through the **cluster resolver**, from the tasks the
OpenShift Pipelines operator installs in the `openshift-pipelines` namespace: no task is
fetched from the internet at run time. If a cluster does not expose them, replace the
`resolver:` block with `name: git-clone` and apply a vendored copy of the task.

Every container image is a **task parameter with a default**, so pointing the pipeline at an
internal mirror is a parameter change rather than an edit to the pipeline:

| Task | Image | Purpose |
|---|---|---|
| helm-validate, helm-deploy | `docker.io/alpine/helm:3.21.4` | Helm CLI |
| helm-validate | `ghcr.io/yannh/kubeconform:v0.8.0-alpine` | schema check |
| smoke-test | `registry.access.redhat.com/ubi9/ubi-minimal` | curl |

The schema location used by `kubeconform` is a parameter too, for clusters without egress to
raw.githubusercontent.com.
