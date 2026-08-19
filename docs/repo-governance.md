# The other half of the boundary

The deploy identity cannot touch production: `deployer` has no rights on production namespaces
and, more fundamentally, no path to that cluster at all. That is proved and re-provable
(`scripts/verify-target.sh`, the `rbac-proof` matrix).

It also protects only half of the path.

Production is not only *operated*, it is **described** — and the descriptors live in our
repositories: `deploy/values-prod.yaml`, the library chart that renders it, the workflow that
packages it. The ISTAT DevOps team applies what those files produce. A change to replica
counts, resource limits, the Route host or the config of production travels to the cluster
through a pull request, and RBAC never sees a pull request.

So the separation of duties has to be reconstructed in GitHub, or it exists on one half of the
journey only. Concretely: **on production, the security boundary is branch protection.**

## What to enable, per repository

`CODEOWNERS` alone does nothing: GitHub only enforces it when the branch is protected and code
owner review is required. On `main`, in all three repositories:

- **Require a pull request before merging** — at least 1 approval.
- **Require review from Code Owners** — this is the setting that gives `CODEOWNERS` teeth.
- **Dismiss stale approvals when new commits are pushed** — otherwise an approved PR can be
  changed after approval and merged with the old review attached.
- **Require status checks to pass**: `validate` (charts), `ci` (services). The schema gate is
  the only automated check that ever looks at the production descriptors, since nobody can
  dry-run them against the production cluster.
- **Do not allow bypassing the above settings**, administrators included. An exception granted
  to admins is an exception granted to whoever holds an admin token.
- **Restrict who can push tags** matching `v*` and `istat-ndc-service-v*`: a tag is what
  triggers a release, and a release is what production is applied from.

`.github/CODEOWNERS` in each repository lists the files that require the DevOps team's review.
Everything else stays with the development team, which is the point: the review requirement is
narrow enough to be respected rather than routed around.

## The placeholder to resolve on day one

`@istat/ndc-devops` does not exist yet. **GitHub ignores unknown code owners silently** — no
warning, no failed check, the rule simply does not apply. So an unresolved placeholder here
does not fail loudly like a missing namespace would; it fails by quietly doing nothing.

Agreeing the real team handle, and verifying that a test pull request on
`deploy/values-prod.yaml` actually requests their review, belongs in the same conversation as
the namespace naming and the registry. It is the cheapest item on that list and the only one
that silently no-ops if forgotten.

## Why not solve this with permissions instead

The tempting alternative is to keep production descriptors in a repository the development team
cannot write to. It costs more than it looks: the values files would drift from the chart that
renders them, and the promotion "same artifact, different values file" would stop being
verifiable from one place. Keeping one source of truth and gating the sensitive files by review
preserves the property that made this design worth building — the environment is a parameter,
not a fork — while still requiring two parties to change production.
