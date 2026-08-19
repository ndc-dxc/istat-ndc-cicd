# Two clusters, two responsibilities

Development and test share one OpenShift cluster. **Production runs on a different cluster**,
and this repository never talks to it. That is not a limitation to work around later — it is
the shape of the delivery model, and most of the design follows from it.

```
   cluster A (dev/test)                         cluster B (prod)
   ────────────────────                         ───────────────
   istat-ndc-cicd   Tekton, deployer SA         istat-ndc-prod
   istat-ndc-dev    ◄── helm upgrade                 ▲
   istat-ndc-test   ◄── helm upgrade                 │
                                                     │
        rendered manifests ──── release artifact ────┘
                                              applied by the ISTAT DevOps team
```

## Who does what

| | Developers (us) | ISTAT DevOps |
|---|---|---|
| Build the image | ✅ GitHub Actions | |
| Deploy to dev, test | ✅ Tekton pipeline | |
| Own the descriptors (chart, values, incl. `values-prod.yaml`) | ✅ | reviews them |
| Promote the image to production | | ✅ |
| Apply to the production cluster | | ✅ |

We reach test. Everything past test — the promotion decision, the credentials, the apply — is
theirs. What we hand over is descriptors and an image, not commands.

## Why the pipeline stops at test

`tekton/tasks/helm-deploy.yaml` refuses any environment other than `dev` and `test`, and the
`deployer` ServiceAccount holds no rights on production namespaces. Both remain true, but note
what actually enforces the boundary here: the pipeline has **no network path and no credentials
to cluster B at all**. RBAC is the second lock, not the first.

## What extending the pipeline to production would really cost

There used to be a `bootstrap/31-rbac-prod.yaml` in this repository, described as "apply this
the day production is opened to the new pipeline". It was removed because it could not do that.

A RoleBinding grants a role to a subject **on the same cluster**. `deployer` is a ServiceAccount
in `istat-ndc-cicd` on cluster A; on cluster B it does not exist. The binding would be accepted
by the API server and grant nothing to nobody — a file that fails silently is worse than no file.

Deploying to cluster B from cluster A would instead require:

1. a kubeconfig or token for cluster B, stored as a Secret **inside the CI/CD namespace**;
2. `helm --kubeconfig` in the deploy task, plus network reachability between the clusters;
3. accepting that a standing credential to production lives next to the pipelines, where any
   change to a Task can use it.

That is a security decision for ISTAT, not a manifest for us to leave lying around ready to
apply. Until it is taken, the answer is the release artifact below.

## The handover: an artifact, not a procedure

Production manifests are rendered from the same chart and the same values as dev and test, by
`scripts/render-prod-manifests.sh` in the charts repository — but that script is **not** meant
to be run by hand at release time. The service repository publishes, on every release tag, a
`prod-manifests` bundle attached to the GitHub release, together with a promotion record:

```
service        sample-service
git revision   086e40749b11d1df93bfd84a0035d276430d1117
image          ghcr.io/ndc-dxc/istat-ndc-sample-service
image digest   sha256:…                 ← what was actually validated in test
chart          istat-ndc-service 0.1.0
values-prod    sha256:…                 ← checksum of the descriptor that was rendered
```

The digest matters more than it looks. If ISTAT mirrors images into an internal registry for
cluster B, `…:086e4074` on ghcr and `…:086e4074` on the internal registry are two labels that
nothing guarantees to be the same bytes. The digest **is** the bytes. It is what lets the
DevOps team state that what went to production is what test validated, instead of trusting a
tag convention.

## Two clusters means two surveys

`scripts/verify-target.sh` takes a role:

```sh
oc login <cluster A> && ./scripts/verify-target.sh --role dev-test
oc login <cluster B> && ./scripts/verify-target.sh --role prod
```

The `prod` profile checks only what genuinely crosses the boundary: whether cluster B can pull
from the agreed registry, whether the SCC model behaves the same (our chart never pins
`runAsUser`, so it must be admitted there too), and what the Route domain is.

## What we ask for, and what we deliberately do not

**We ask for read-only (`view`) on the production namespace.** It grants no write power and
costs nothing, and it closes the most likely failure of this whole arrangement: descriptors
live in our repository while the cluster is operated by someone else, so a hotfix applied
directly to production would be silently reverted by the next render. Read access lets us
diff descriptor against reality and see the drift.

**We do not ask for server-side dry-run on production.** Kubernetes has no dry-run-only
permission: `--dry-run=server` is authorised as the real write verb, so requesting it would
mean requesting write access to production — dismantling the separation this document exists
to describe. Validation against the real admission chain stays with the team that owns the
cluster. On our side the prod descriptors get schema validation (`helm template` piped into
`kubeconform -strict`) and drift detection, and that is the correct place for the line.
