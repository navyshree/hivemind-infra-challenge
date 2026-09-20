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
egress, and `github_repository=owner/repo` to create the OIDC deploy role.

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

**Not covered:** TLS, WAF, a private API endpoint, restricted node egress. See
[Tradeoffs](#tradeoffs).

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

Autoscaling was measured, not assumed: under load the HPA scaled **3 → 7
replicas** on real `metrics-server` metrics, held the zone-spread constraint at
2/2/3, registered every new pod in the ALB target group, and scaled back to 3
afterwards.

### Reliability

Replicas spread across three AZs under a **hard** `topologySpreadConstraint`
(`DoNotSchedule`), scoped by `matchLabelKeys: [pod-template-hash]`. That last
part is load-bearing: without it the constraint counts both ReplicaSets during a
surge rollout and the surviving set can land 2/1/0 across three zones. That is
not hypothetical — it happened on this cluster before the fix.

Zero-downtime deploys rest on a chain that must hold end to end: ALB pod
readiness gate → `maxUnavailable: 0` → 10s `preStop` sleep → 20s ALB
deregistration delay → 40s termination grace → the server's own 15s drain. Each
window fits inside the next. The `preStop` uses the native `sleep` action rather
than an exec hook, because the image has no shell.

A `PodDisruptionBudget` (`maxUnavailable: 1`, `unhealthyPodEvictionPolicy:
AlwaysAllow`) keeps two replicas up during node drains without letting a broken
pod wedge the drain. One NAT gateway per AZ means losing an AZ does not sever
egress for the survivors. Control plane logs go to CloudWatch;
`eks-node-monitoring-agent` feeds node auto-repair.

---

## Tradeoffs

Ordered by how much they would matter in production.

**1. No TLS.** The ALB listens on HTTP/80 only. HTTPS needs a domain and an ACM
certificate, neither of which this exercise provisions, so **traffic is
unencrypted in transit — unacceptable for real production**. The annotations are
written and commented in [`ingress.yaml`](k8s/base/ingress.yaml): add
`certificate-arn`, add 443 to `listen-ports`, set `ssl-redirect: "443"` and pin
`ELBSecurityPolicy-TLS13-1-2-2021-06`.

**2. Terraform state is local.** A shared environment needs a remote backend
with locking or two concurrent applies corrupt state. The S3 backend block with
S3-native locking is written and commented in
[`versions.tf`](terraform/versions.tf). It is off because the bucket cannot live
in the state that stores it — a bootstrap step that is ceremony for a
single-operator review environment. **This becomes the top priority the moment a
second person touches it.**

**3. The Kubernetes API endpoint is public.** `0.0.0.0/0`, because
GitHub-hosted runners egress from a large rotating range and a reviewer connects
from an unknown network. Mitigated by `authentication_mode = "API"`:
reachability alone grants nothing without an authorised IAM principal. The real
fix is architectural — a private endpoint reached over PrivateLink from
self-hosted runners or CodeBuild.

**4. Observability stops at the edges of the application.** Structured JSON logs
to stdout, `metrics-server` for the HPA, control plane logs in CloudWatch, and
CloudWatch alarms on target 5xx, unhealthy targets, p99 latency and failed
nodes, delivered to SNS. The notification path is proven end to end: a forced alarm executed its SNS
action and the mail arrived in a real inbox, for both the ALARM and the OK
transition.

What is missing is the inside of the service: no `/metrics` endpoint, no
tracing, no pod log shipping. So the alarms can say it is unhealthy but not why,
which still leaves a real gap at 3am. Production wants RED metrics scraped by
`amazon-cloudwatch-observability` or Prometheus, OpenTelemetry tracing, and
Fluent Bit shipping pod logs. The `failed-nodes` alarm additionally sits in
`INSUFFICIENT_DATA` until that observability addon is installed, since nothing
publishes `ContainerInsights` metrics without it.

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
`overlays/{dev,staging,prod}`; actions pinned by tag rather than commit SHA;
no secrets management (the service needs none — when it does, the answer is the
External Secrets Operator, not Kubernetes `Secret` objects in Git); and a single
region, so an AZ failure is survived and a region failure is not.

---

## Operational gotchas

Things that will bite someone who did not write this.

- **Teardown order is not optional.** The ALB is created by the controller, not
  by Terraform. Destroy infrastructure first and its ENIs strand in the subnets
  and hang VPC deletion. Use `make destroy`.
- **`HELLO_TAG` must stay tied to the image tag.** CD writes both from the same
  value. Setting it by hand for a quick rollout makes the service advertise a
  release that does not exist — the tag stops meaning anything.
- **HPA `minReplicas` must stay at or above the AZ count.** Drop it to 1 and
  the zone-spread constraint still passes while the availability story is gone.
- **ECR tags are immutable.** Rebuilding the same commit cannot re-push the same
  tag; the push fails rather than silently replacing. Intended — but it means a
  retry after a partial failure needs a new tag.
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

Static gates, all clean: Go tests under `-race`, `golangci-lint`,
`terraform validate` and `tflint`, `kubeconform -strict` against 1.36, `trivy`
over Terraform, manifests, Dockerfile and image, and `actionlint`.

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
- Add TLS once a domain and ACM certificate exist.
