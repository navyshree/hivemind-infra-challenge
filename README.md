# Hivemind Infrastructure Challenge — Greeter Service

A Go web service on EKS, provisioned end to end with Terraform, with a CI/CD
pipeline. Deployed and exercised on real AWS; the evidence is at the bottom.

| Asked for | Where |
|---|---|
| Deploy to AWS using Terraform | [`terraform/`](terraform/) |
| `HELLO_TAG` set to a unique value | [`k8s/base/greeter.env`](k8s/base/greeter.env) — CD overwrites it with the deployed image tag |
| URL parameter on the greeter | [`app/greeter.go`](app/greeter.go) — `?name=` |
| Highly available Kubernetes | EKS across 3 AZs, [below](#architecture) |
| CI/CD pipeline | [`.github/workflows/`](.github/workflows/) |
| Production-ready | [below](#production-readiness) |
| Tradeoffs documented | [below](#tradeoffs) |

---

## Architecture

```
                         Internet
                             │
                 ┌───────────▼───────────┐
                 │  Application LB       │  created by the AWS Load Balancer
                 │  (3 public subnets)   │  Controller from the Ingress object
                 └───────────┬───────────┘
                             │  target-type: ip — straight to pod IPs, which
                             │  is what pod readiness gates require
        ┌────────────────────┼────────────────────┐
   ┌────▼─────┐        ┌─────▼────┐        ┌──────▼───┐
   │   AZ a   │        │   AZ b   │        │   AZ c   │
   │  ┌────┐  │        │  ┌────┐  │        │  ┌────┐  │
   │  │pod │  │        │  │pod │  │        │  │pod │  │
   │  └────┘  │        │  └────┘  │        │  └────┘  │
   │ node/priv│        │ node/priv│        │ node/priv│
   └────┬─────┘        └─────┬────┘        └──────┬───┘
        │                    │                    │
    ┌───▼───┐            ┌───▼───┐            ┌───▼───┐
    │  NAT  │            │  NAT  │            │  NAT  │   egress
    └───────┘            └───────┘            └───────┘
```

Nothing but the load balancers is public. Nodes sit in private subnets and
reach the internet through per-AZ NAT.

---

## Quickstart

**Prerequisites:** Terraform ≥ 1.10, AWS CLI, kubectl, Docker. Credentials
need VPC, EKS, IAM and ECR permissions. If they are temporary, check the expiry
first — an EKS apply takes ~20 minutes and a mid-apply expiry leaves partial
state.

```shell
cd terraform && terraform init && terraform apply     # ~20 min
aws eks update-kubeconfig --region eu-central-1 --name hivemind-greeter
kubectl apply -k k8s/base
kubectl -n hivemind-greeter rollout status deployment/hivemind-greeter
make url                                              # prints the public URL
```

Useful variables: `region`, `kubernetes_version` (keep it in **standard**
support — extended support bills at $0.60/cluster-hour instead of $0.10),
`single_nat_gateway=true` to save ~$76/month at the cost of AZ-independent
egress, `github_repository=owner/repo` to create the OIDC deploy role, and
`alert_email` to wire up the CloudWatch alarms. The full set, with the
reasoning behind each default, is in
[`terraform/variables.tf`](terraform/variables.tf).

The last two gate their resources on a non-empty value, so pass them on every
run once you have used them — a later `plan` without them is not drift, it is
Terraform correctly proposing to destroy what those variables switch on. Put
them in `terraform.tfvars` (gitignored) rather than retyping them.

For HTTPS, apply the TLS overlay instead of `k8s/base` — the base has no 443
listener, so applying it to a cluster that has one takes HTTPS away:

```shell
ARN=$(scripts/tls-selfsigned.sh)     # or an ACM certificate you already own
kubectl kustomize k8s/overlays/tls | sed "s|REPLACE-ME|${ARN}|" | kubectl apply -f -
```

### Using it

```shell
curl "http://${ALB}/"          # Hello, 203.0.113.9! I'm greeter-7d9c…-x2kql (tag: sha-a1b2c3d4)
curl "http://${ALB}/?name=Ada" # Hello, Ada! I'm greeter-7d9c…-x2kql (tag: sha-a1b2c3d4)
curl "http://${ALB}/healthz"   # ok
```

The hostname is the pod name, so repeated calls show the ALB spreading traffic.
`HELLO_TAG` is the deployed image tag, so a response identifies its exact build.

### Tearing down

**Order matters.** The ALB is created by the controller from the Ingress, so
Terraform does not know about it. Destroying infrastructure first strands the
ALB's ENIs in the subnets and hangs VPC deletion.

```shell
make destroy   # deletes the workload, waits for the ALB, then terraform destroy
```

---

## Production readiness

### Security

The container is `FROM scratch`: under 3 MiB, one layer per architecture, no
shell, no package manager, **0 vulnerabilities** reported by Trivy. It runs as UID 65532 with a
read-only root filesystem, all capabilities dropped, `seccompProfile:
RuntimeDefault` and `allowPrivilegeEscalation: false`. The namespace enforces
the `restricted` Pod Security Standard, so a workload asking for privilege is
rejected at admission.

Nodes require **IMDSv2 with hop limit 1**, which stops a compromised pod
reaching instance metadata to steal the node role's credentials. The Load
Balancer Controller uses IRSA rather than node credentials. Cluster access uses
EKS access entries (`authentication_mode = "API"`), and the CD role is scoped to
**edit within one namespace**, not cluster admin — which is only possible
because the namespace is created by Terraform rather than by the pipeline.

**NetworkPolicy is enforced**, default-deny in the namespace, admitting only the
public subnet CIDRs (where the ALB's ENIs live) on 8080. Note this needs two
things: the policy objects *and* `enableNetworkPolicy` on the VPC CNI addon.
Without the latter the policies are accepted and enforce nothing — a cluster
that looks segmented and is not.

The `name` parameter is caller-controlled and echoed back, so it is trimmed,
stripped of control characters (CR/LF would forge lines into the JSON logs),
and truncated to 64 characters by rune. Responses are pinned to `text/plain`
with `nosniff`.

CI authenticates to AWS by **GitHub OIDC** — no long-lived key exists in the
repository — and the trust policy is scoped by `sub` to this repo and to `main`
or the `production` environment. ECR tags are immutable with scan-on-push.

TLS 1.3 terminates at the ALB, though on a self-signed certificate — see
[Tradeoffs](#tradeoffs) for what that does and does not buy.

**Not covered:** a publicly trusted certificate, WAF, a private API endpoint,
restricted node egress. See [Tradeoffs](#tradeoffs).

### Performance

Requests are set (50m CPU / 64Mi) with a **memory limit equal to its request and
deliberately no CPU limit** — a CPU limit throttles via CFS quota even on an
idle node, adding tail latency for nothing, while the request already guarantees
the scheduler share. Memory is incompressible, so a leak should be OOM-killed
rather than starve its neighbours.

The ALB routes to pod IPs directly (`target-type: ip`), removing the kube-proxy
hop. The Go server sets explicit read, write and idle timeouts; Go's defaults
are unlimited, which is a slow-client exhaustion vector. The sub-3 MiB image
keeps pull time negligible during scale-out.

The HPA scales 3–12 on CPU against `metrics-server`. Measured behaviour under
load is in [Verified](#verified).

### Reliability

Replicas spread across three AZs under a **hard** `topologySpreadConstraint`
(`DoNotSchedule`), scoped by `matchLabelKeys: [pod-template-hash]` so the count
covers one revision rather than both during a rollout — see
[Verified](#verified) for why that scoping is load-bearing.

Zero-downtime deploys rest on a chain that must hold end to end: ALB pod
readiness gate → `maxUnavailable: 0` → 10s `preStop` sleep → 20s ALB
deregistration delay → 40s termination grace → the server's own 15s drain. Each
window fits inside the next. The `preStop` uses the native `sleep` action rather
than an exec hook, because the image has no shell.

A `PodDisruptionBudget` (`maxUnavailable: 1`, `unhealthyPodEvictionPolicy:
AlwaysAllow`) keeps two replicas up during node drains without letting a broken
pod wedge the drain. One NAT gateway per AZ means losing an AZ does not sever
egress for the survivors. Control plane logs go to CloudWatch.

Node auto-repair is **enabled and bounded**: `eks-node-monitoring-agent` detects
kernel, networking and storage faults, and `node_repair_config` lets EKS act on
them — capped at one node at a time, because with three nodes an unbounded
repair could remove a third of the group while the replacement boots, and the
zone-spread constraint is `DoNotSchedule`, so displaced pods would stay Pending
rather than move. Installing the agent without the config is a common trap: EKS
sees the faults and does nothing.

**Recovery.** The service is stateless — no database, no volumes, no
StatefulSets — so there is nothing to back up and RPO is not a meaningful
number. Losing the region means rebuilding from this repository:
`terraform apply -var region=<other>`, then one CD run. Region, availability
zones and AMIs are all derived rather than hardcoded, so that is a variable
change rather than a rewrite, bounded by EKS control-plane creation at roughly
20 minutes. Two things make it slower than that sounds: ECR is not replicated,
so the image is rebuilt from source, and with no domain the replacement load
balancer answers on a different hostname that has to be handed out by hand.
**This is a plan, not a rehearsal — it has never been executed.**

---

## Tradeoffs

Ordered by how much they would matter in production.

**1. TLS is self-signed, so it is not publicly trusted.** HTTPS works — the ALB
terminates **TLS 1.3** on an `ELBSecurityPolicy-TLS13-1-2-2021-06` listener, and
the certificate carries the load balancer's own hostname in its SAN, so the only
thing wrong with it is the issuer. What is missing is a signature from a CA
browsers already trust, which needs a domain this exercise does not own.

Two consequences, both deliberate. There is **no `ssl-redirect`**: forcing 80
onto a self-signed 443 would put every visitor behind a browser interstitial,
which is worse than plain HTTP, so HTTPS is offered *alongside* port 80 rather
than in place of it. And there is **no HSTS**, because pinning clients to an
endpoint they cannot validate is a hard mistake to undo.

Closing it properly is a domain and about ten minutes: issue a public ACM
certificate with DNS validation, swap the ARN, turn on `ssl-redirect`, then add
HSTS. Reproduce the current certificate with
[`scripts/tls-selfsigned.sh`](scripts/tls-selfsigned.sh); the overlay is
[`k8s/overlays/tls/`](k8s/overlays/tls/).

**2. Terraform state is local.** A shared environment needs a remote backend
with locking or two concurrent applies corrupt state. The S3 backend block with
S3-native locking is written and commented in
[`versions.tf`](terraform/versions.tf). It is off because the bucket cannot live
in the state that stores it — a bootstrap step that is ceremony for a
single-operator review environment. That file is also the only record of what
exists: lose it and the running stack can only be dismantled by hand in the
console. **This becomes the top priority the moment a second person touches it,
or the environment outlives a laptop.**

**3. The Kubernetes API endpoint is public.** `0.0.0.0/0`, because
GitHub-hosted runners egress from a large rotating range and a reviewer connects
from an unknown network. Mitigated by `authentication_mode = "API"`:
reachability alone grants nothing without an authorised IAM principal. The real
fix is architectural — a private endpoint reached over PrivateLink from
self-hosted runners or CodeBuild.

**4. Metrics are exposed but nothing collects them.** Structured JSON logs to
stdout, `metrics-server` for the HPA, control plane logs in CloudWatch, and
CloudWatch alarms on target 5xx, unhealthy targets, p99 latency and node
capacity, delivered to SNS. The notification path is proven end to end: a forced
alarm executed its SNS action and the mail arrived in a real inbox, for both the
ALARM and the OK transition.

RED metrics are exposed in Prometheus format on port 9090 — counts by status, a
latency histogram, build info, uptime — on a separate port so `/metrics` is
unreachable through the load balancer, with the NetworkPolicy already admitting
a scraper. What is missing is everything that reads them: no collector, no
tracing, no pod log shipping. The alarms can say the service is unhealthy but
not why, which remains the real gap at 3am.

**5. No node autoscaling.** The node group has `max_size = 6` but nothing drives
it. At current sizing the HPA ceiling of 12 pods fits comfortably on 3 nodes
(12 × 50m against 5790m allocatable), so this is not currently a limit — but a
larger workload would leave pods Pending with no remedy. Karpenter is the
current answer.

**6. Autoscaling is CPU-based.** For a service this cheap CPU is a weak proxy
for user experience. RPS or p99 latency via KEDA would track what users feel;
CPU needs only `metrics-server`, which is a managed addon.

Also deliberately out of scope, each a small change rather than a redesign: no
WAF (one annotation plus an ACL); unrestricted node egress (needs ~a dozen VPC
endpoints at ~$7/month each); a single environment rather than
`overlays/{dev,staging,prod}`;
no secrets management (the service needs none — when it does, the answer is the
External Secrets Operator, not Kubernetes `Secret` objects in Git); and a single
region, so an AZ failure is survived and a region failure is not.

---

## Operational gotchas

Things that will bite someone who did not write this.

- **Teardown order is not optional** — see [Tearing down](#tearing-down). Use
  `make destroy`.
- **`HELLO_TAG` must stay tied to the image tag.** CD writes both from the same
  value. Setting it by hand for a quick rollout makes the service advertise a
  release that does not exist — the tag stops meaning anything.
- **HPA `minReplicas` must stay at or above the AZ count.** Drop it to 1 and
  the zone-spread constraint still passes while the availability story is gone.
- **ECR tags are immutable.** Rebuilding the same commit cannot re-push the same
  tag; the push fails rather than silently replacing. Intended — and it does not
  block a retry: the tag is commit-derived and cannot be reminted, so dispatch
  the CD workflow with `image_tag=sha-<commit>` instead. That skips the build
  entirely and resumes at the image-exists check.
- **`terraform destroy` can leave an orphaned control-plane log group.** EKS
  flushes buffered events after the group is deleted, which re-creates it; the
  next `apply` then fails with `ResourceAlreadyExistsException` on
  `/aws/eks/<cluster>/cluster`. Delete it before re-applying:
  `aws logs delete-log-group --log-group-name /aws/eks/hivemind-greeter/cluster`.
  Do *not* "fix" this with `create_cloudwatch_log_group = false` — AWS then
  auto-creates the group and silently discards the 30-day retention, leaving
  control-plane logs on Never-expire.
- **`force_delete = true` on the ECR repository** means `terraform destroy`
  takes the image history with it. Fine for a review environment, wrong for one
  you might need to roll back.
- **The NetworkPolicy CIDRs are VPC-shaped.** They are literals because
  Kustomize cannot read Terraform. `scripts/check-cidrs.py` fails CI if they
  drift from `var.vpc_cidr`; do not silence it.
- **Readiness gates are absent on a service's very first deploy.** The
  controller's webhook only injects them once a `TargetGroupBinding` exists, so
  the initial rollout has a weaker guarantee than every one after it.
- **ECR BASIC scanning cannot read this image.** A scratch image has no OS and
  no package manager, so scans fail with `UnsupportedImageError`. The flag is
  left enabled because it becomes real under Enhanced scanning; until then
  Trivy in CI is the control.
- **GitHub issues OIDC subjects in two shapes.** Every AWS and GitHub example
  shows `repo:owner/name:…`, but an id-qualified form —
  `repo:owner@<id>/name@<id>:…` — also exists, and which one you get is not
  under the workflow's control. A trust policy written from the docs fails
  against it with nothing more informative than
  `Not authorized to perform sts:AssumeRoleWithWebIdentity`. The policy here
  accepts both.
- **SNS alarm email lands in spam.** Observed, not theoretical: the
  subscription confirmation went to spam, and a confirmation nobody clicks
  leaves the subscription in `PendingConfirmation` — alarms fire, the action
  succeeds, and nothing reaches a human. Allowlist
  `no-reply@sns.amazonaws.com`, and verify with
  `aws sns list-subscriptions-by-topic`: an ARN of `PendingConfirmation` means
  the alerting is decorative. For anything that matters, prefer a chat webhook
  or PagerDuty over email for exactly this reason.
- **Node-level termination is not budgeted.** The pod drain chain fits in 40s,
  but nothing here handles a node going away underneath it. Adopting spot or
  Karpenter means adding that budget — see
  [ADR 0001](docs/decisions/0001-fixed-node-group-over-karpenter.md).

## References

Upstream issues and docs this design leans on.

- [karpenter#1599](https://github.com/kubernetes-sigs/karpenter/issues/1599),
  [karpenter#2600](https://github.com/kubernetes-sigs/karpenter/issues/2600),
  [kubernetes#90977](https://github.com/kubernetes/kubernetes/issues/90977) —
  eviction and consolidation versus PodDisruptionBudgets; the reasoning in
  ADR 0001.
- [EKS Kubernetes version support](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html)
  — standard versus extended support, and the billing difference.
- [aws-load-balancer-controller](https://github.com/kubernetes-sigs/aws-load-balancer-controller)
  — the chart skipped 2.x entirely, so chart 3.5.0 is controller v3.5.0 and a
  "1.x" chart is old rather than stable.
- [Pod readiness gates](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/pod_readiness_gate/)
  — why the namespace carries `elbv2.k8s.aws/pod-readiness-gate-inject`.
- [matchLabelKeys in topology spread](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/)
  — why the spread constraint is scoped to `pod-template-hash`.

## Cost

Rates from the AWS Price List API for `eu-central-1`, 2026-09-20.

| Component | Rate | ~Monthly |
|---|---|---|
| EKS control plane | $0.10/hr | ~$73 |
| NAT gateway × 3 | $0.052/hr each | ~$114 + data |
| Application Load Balancer | $0.027/hr + LCU | ~$20 |
| 3 × t3.medium | $0.048/hr each | ~$105 |
| **Total** | **~$0.43/hr** | **~$310** |

All rates verified against the AWS Pricing API for `eu-central-1`.

`single_nat_gateway=true` removes ~$76/month. Spot capacity would cut compute
substantially for a stateless workload. **Destroy between sessions** — idle, this
is ~$10/day.

---

## Verified

Everything below was executed against the live stack, not asserted. `make check`
reproduces the static half; CI runs it on every push.

- **Zero downtime, through the internet-facing ALB:** 206 requests across a full
  three-pod replacement, **0 failures**; 186 / 0 on a second rollout after the
  spread fix.
- **Autoscaling:** the HPA scaled 3 → 7 on real metrics under load, held the
  zone spread at 2/2/3, and returned to 3.
- **NetworkPolicy:** a pod in another namespace reached the service before the
  policy and times out after it; the ALB path is unaffected.
- **Alerting:** a forced alarm executed its SNS action and the mail arrived, on
  both the ALARM and the OK transition.
- **Pipeline:** CI green across four jobs; CD built, pushed and deployed a
  multi-arch image over OIDC with no static key present, and a rollback to an
  earlier tag was tested.
- **Teardown:** deleting the Ingress released the ALB and its ENIs, which is the
  step that makes `terraform destroy` terminate rather than hang.
- **TLS:** the ALB negotiates `TLSv1.3 / AEAD-AES128-GCM-SHA256` and serves the
  application over it; port 80 still answers 200, so no visitor is pushed into
  a certificate warning, and it survives a full CD run.
- **Metrics:** counters move by status class and the histogram's `+Inf` bucket
  equals the observation count, checked against a running container.

Static gates, all clean: Go tests under `-race` with a coverage floor,
`golangci-lint`, `govulncheck`, `terraform validate` / `test` / `tflint`,
`kubeconform -strict`, `trivy` over Terraform, manifests, Dockerfile and image,
and `actionlint`.

**The finding worth the space:** pods landed **2/1/0 across AZs** despite a hard
spread constraint, because it counts both ReplicaSets during a surge rollout.
Every placement was individually legal; the surviving set was not. Fixed with
`matchLabelKeys`, re-verified 1/1/1. Linting and schema validation cannot see
this — it only appears on a real multi-AZ cluster, which is the argument for
deploying early rather than polishing locally.

**Not verified:** no AZ failure was simulated. One pod per AZ is confirmed;
surviving the loss of an AZ is inferred from that.

### TODO

- Add an application `/metrics` endpoint and tracing.
- Switch the registry to Enhanced scanning (`enable_enhanced_scanning = true`);
  BASIC scanning cannot read a scratch image.
- Terminate a node, and ideally cordon an AZ, to turn the AZ-tolerance claim
  from inference into evidence.
- Replace the self-signed certificate with a publicly trusted one once a
  domain exists, then enable `ssl-redirect` and HSTS.
