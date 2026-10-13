# Access requests

How a service gets access to anything outside its own namespace: another
team's service, an AWS resource, or an external API.

## Ask for access

Add a file under `access-requests/<environment>/` and open a PR:

```yaml
apiVersion: ridgeline.dev/v1alpha1
kind: AccessRequest
metadata:
  name: verify-api-score-and-publish
spec:
  requester: you@example.com
  ticket: PLAT-142                  # links the grant to the reason
  environment: staging
  subject: identity/verify-api       # namespace/serviceaccount
  expires: "2026-11-06"              # required; max 30 days in staging
  justification: >
    Why the service needs this, in a sentence a reviewer can check.
  grants:
    - resource: svc/risk-scorer      # network path, from catalog.yaml
    - resource: sqs/verification-events
      actions: [sqs:SendMessage, sqs:GetQueueAttributes]
```

CI posts the plan on your PR: what changes, until when, and which teams must
approve. Fix anything it flags; the messages say what to change.

## What happens on merge

- `accessctl render` writes:
  - `rendered/<env>/iam/<name>.tf.json`: an IAM policy with exactly the
    listed actions on exactly the catalog ARNs, attached to the workload's
    IRSA role `<env>-<namespace>-<name>`. Applied by Terraform.
  - `rendered/<env>/network/<name>.yaml`: matching egress and ingress
    NetworkPolicies. Applied by Argo CD.
- Every object is tagged/annotated with request name, ticket, requester,
  expiry and a request hash.

## Expiry

A nightly workflow opens a PR deleting expired requests (and lists those
expiring within 7 days). Merging it removes the grants. To keep access,
open a PR extending `expires`.

## The rules

| Rule | Why |
|---|---|
| Resources and actions come from `catalog.yaml` only | Least privilege is decided once per resource, by its owner |
| No wildcard actions | `s3:*` is how a read grant becomes a delete grant |
| `expires` is required, max 90/30/14 days (dev/staging/prod) | No standing access |
| PII outside prod needs `riskException` and ≤14 days | Real data off-prod only under an approved, time-boxed exception |
| PII grants require `@ridgeline/security` | Second pair of eyes on sensitive data |
| Owner of the target must approve | The team that runs risk-scorer decides who calls it |
| Unknown YAML fields are errors | A typo should fail loudly, not be ignored |

Commands:

```bash
go run ./tools/accessctl validate access-requests/
go run ./tools/accessctl explain  access-requests/staging/my-request.yaml
go run ./tools/accessctl render   access-requests/      # make access-render
go run ./tools/accessctl expired  -within 7 access-requests/
```
