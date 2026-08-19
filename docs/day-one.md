# Day one on the ISTAT cluster

The sequence to follow the first time these manifests meet the real cluster. Everything here
has been rehearsed end to end on a single-node OpenShift, so this is a checklist, not a design
exercise. Each step says who runs it and how to tell it worked.

**Which cluster**: steps 1 to 7 all happen on the **dev/test cluster**. Production is a separate
cluster that this repository never contacts — see [cross-cluster.md](cross-cluster.md). Step 0
is the only one that runs twice.

## 0. Survey both clusters — platform team, read-only

```sh
oc login <dev/test cluster> && ./scripts/verify-target.sh --role dev-test
oc login <prod cluster>     && ./scripts/verify-target.sh --role prod
```

The `dev-test` profile reports versions, the tasks and ClusterRoles the pipeline relies on,
storage classes, quotas without limit ranges, and whether the cluster can pull from the
registry. The `prod` profile checks only what crosses the boundary between the two clusters:
registry reachability, the SCC/UID model, the Route domain, and whether we can read production
well enough to detect drift. Differences are not necessarily problems — each has a documented
variant — but they must be decided here rather than discovered during the first deploy.

Images are tagged by commit SHA only, so pass a real one:
`PROBE_IMAGE=ghcr.io/<owner>/<service>:<sha> ./scripts/verify-target.sh --role prod`.

## 1. Bootstrap — OPS, one command

```sh
oc apply -k bootstrap/
```

Applied to the **dev/test cluster**. Creates three namespaces — `cicd`, `dev`, `test` — with
quotas and limit ranges, the `deployer` ServiceAccount, its role bindings on dev and test, the
workspace PVC, and the two grants explained in the proposal: a read-only ClusterRoleBinding for
the EventListener and `pipelines-scc` **scoped to the CI/CD namespace**.

There is no production namespace in the bundle: production is a different cluster, and creating
an empty `istat-ndc-prod` here would describe a topology that does not exist.

Verify:

```sh
SA=system:serviceaccount:istat-ndc-cicd:deployer
oc auth can-i create deployments -n istat-ndc-dev  --as=$SA   # yes
oc auth can-i create deployments -n istat-ndc-test --as=$SA   # yes
oc auth can-i get    nodes                         --as=$SA   # no
```

The PVC stays `Pending` until the first pod claims it. That is the storage class waiting for a
consumer, not a failure.

## 2. Webhook secret — OPS

Only for the inbound-webhook variant.

```sh
oc create secret generic github-webhook-secret \
  --from-literal=secretToken="$(openssl rand -hex 32)" -n istat-ndc-cicd
```

The same value goes into the service repository as the `DEPLOY_WEBHOOK_SECRET` secret.

## 3. Pipelines — platform team

```sh
oc apply -k tekton/
oc get route github-listener -n istat-ndc-cicd -o jsonpath='{.spec.host}'
```

## 4. Prove the trigger refuses what it should — platform team

Before proving it works, prove it does not work when it should not:

```sh
WEBHOOK_SECRET=wrong ./scripts/simulate-webhook.sh https://<listener-host> sample-service dev abc123
WEBHOOK_SECRET=<real> ./scripts/simulate-webhook.sh https://<listener-host> sample-service prod abc123
oc get pipelinerun -n istat-ndc-cicd     # must still be empty
```

The listener answers 202 to everything — that is how an EventListener behaves. The evidence is
the absence of a PipelineRun.

## 5. First deploy — platform team, OPS watching

```sh
WEBHOOK_SECRET=<real> ./scripts/simulate-webhook.sh https://<listener-host> sample-service dev <sha>
tkn pipelinerun logs -f -n istat-ndc-cicd
```

Done when the service answers with the tag that was just released:

```sh
curl -s https://<service-route>/health
# {"status":"UP","environment":"dev","imageTag":"<sha>", …}
```

A deploy that "succeeded" without the live service reporting the new tag has not been verified.

## 6. Prove the rollback — platform team

Deploy a tag that does not exist. The rollout never becomes healthy, `helm --atomic` restores
the previous release, and — because the chart rolls with `maxUnavailable: 0` — the live service
keeps answering with the old tag throughout.

## 7. Promotion to test

The same request with `env: test` and the **same image tag**. Nothing is rebuilt; only the
values file applied changes.

## 8. Settle the two placeholders — platform team with ISTAT

Two things in this repository are deliberately unresolved, and they fail in opposite ways.

The `istat-ndc-*` namespace root fails **loudly**: get it wrong and nothing deploys.

`@istat/ndc-devops` in `.github/CODEOWNERS` fails **silently**: GitHub ignores unknown code
owners without any warning, so the review requirement on the production descriptors simply does
not apply. Agree the real team handle, enable the branch protection described in
[repo-governance.md](repo-governance.md), and verify with a throwaway pull request on
`deploy/values-prod.yaml` that the review is actually requested. This is the cheapest item on
the day-one list and the only one that no-ops quietly if forgotten.

## What stays out of scope: production

Production runs on a **separate cluster**, released by the existing ISTAT blue/green pipelines,
and promotion is the DevOps team's responsibility. This pipeline refuses any environment other
than dev and test — the guard is in the deploy task, so it holds for manual runs too — and it
holds no credentials for that cluster in the first place.

What we hand over is not a procedure but an artifact: the `release-prod` workflow in the service
repository renders the manifests for both colours and publishes them, with a promotion record
naming the **image digest** validated in test, as a GitHub release. Across two registries a tag
is a label; the digest is the bytes. See [cross-cluster.md](cross-cluster.md).
