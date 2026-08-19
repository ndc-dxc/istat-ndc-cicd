# Day one on the ISTAT cluster

The sequence to follow the first time these manifests meet the real cluster. Everything here
has been rehearsed end to end on a single-node OpenShift, so this is a checklist, not a design
exercise. Each step says who runs it and how to tell it worked.

## 0. Survey the cluster — platform team, read-only

```sh
oc login <cluster>
./scripts/verify-target.sh
```

Reports versions, the tasks and ClusterRoles the pipeline relies on, storage classes, quotas
without limit ranges, and whether the cluster can pull from the registry. Differences are not
necessarily problems — each has a documented variant — but they must be decided here rather
than discovered during the first deploy.

## 1. Bootstrap — OPS, one command

```sh
oc apply -k bootstrap/
```

Creates the four namespaces with quotas and limit ranges, the `deployer` ServiceAccount, its
role bindings on dev and test, the workspace PVC, and the two grants explained in the
proposal: a read-only ClusterRoleBinding for the EventListener and `pipelines-scc` **scoped to
the CI/CD namespace**. Production RBAC is deliberately excluded.

Verify:

```sh
SA=system:serviceaccount:istat-ndc-cicd:deployer
oc auth can-i create deployments -n istat-ndc-dev  --as=$SA   # yes
oc auth can-i create deployments -n istat-ndc-prod --as=$SA   # no
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

## What stays out of scope

Production is released by the existing ISTAT blue/green pipelines on their own namespace. The
`deployer` ServiceAccount has no access there, and this pipeline refuses any environment other
than dev and test — the guard is in the deploy task, so it holds for manual runs too.
`scripts/render-prod-manifests.sh` in the charts repository renders the chart into the flat
manifest layout those pipelines consume.
